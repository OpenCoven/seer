#!/usr/bin/env python3
"""Descriptor-anchored renderer asset traversal/hashing helper.

Ports, byte-for-byte in observable contract, the deleted
`renderer-asset-digest.swift` helper: `scripts/renderer-build-identity.mjs`
reads *this file's own source bytes* fresh from disk and pipes them,
verbatim, to the trusted system interpreter's stdin
(`/usr/bin/python3 -I -`) - this file is never compiled, never written to a
temporary file, and never executed by a repository-relative pathname. There
is accordingly no shared canonical executable, no cache, no private run
directory, and no publication/execution TOCTOU: the only "artifact" of any
invocation is a single, short-lived `/usr/bin/python3` process that reads its
own program from stdin and exits. `-I` (isolated mode) means that process
never honors an inherited `PYTHONPATH`, never adds the current working
directory to `sys.path`, and never consults user site-packages/
`sitecustomize` - so nothing this process happens to be spawned with, or
from, can substitute a hostile module for a real standard-library one this
file imports.

CLI contract (all consumed positionally/by flag, no environment lookups of
its own beyond what CPython itself always honors):

    <absolute-renderer-root>
    [--test-action <base64-json>]
    [--deadline-seconds <positive-integer>]

`--test-action` is test-only: production never supplies it (see
`run_test_action` below for the fixed, closed set of narrow, in-process
actions it can request).

Emits a JSON array of ``{"relativePath": ..., "sha256": ...}`` objects,
canonically sorted, to stdout on success (exit 0). Emits a single
human-readable line to stderr and exits 1 on any failure.

Traversal/identity contract (see `ObservedIdentity` below): every directory
component from the filesystem root down through, and including, the
renderer root, and every renderer asset and renderer-owned subdirectory
beneath it, is opened by descriptor - anchored to its already-opened parent
via `dir_fd`, with `O_NOFOLLOW` so a symlink planted at any single path
component is always rejected rather than silently followed - and that
descriptor is retained (never closed) until the whole computation finishes.
Every descriptor is independently re-verified, by descriptor (never by
re-resolving a pathname), both immediately after collection completes and
again after every asset has been hashed, so a path swapped out from under
an already-open descriptor at any point is always detected, never silently
trusted.
"""

import base64
import errno
import hashlib
import json
import os
import signal
import stat
import sys
import time


# ---------------------------------------------------------------------------
# Defensive bounds. None of these exist in the ported Swift contract - a real
# renderer build never comes close to any of them - they are new,
# independent defense-in-depth limits against a pathological or adversarial
# input tree (millions of tiny files, unbounded nesting, a single huge
# file). Deliberately plain module-level constants rather than CLI flags:
# production never needs to tune these per invocation, and a test that needs
# to reach one quickly can do so by supplying a slightly patched copy of
# this exact source (only the constant's value changed, never the logic) to
# the same stdin-execution entry point production uses - proving, in the
# same motion, that execution follows the exact bytes supplied and nothing
# about an on-disk path.
MAX_ENTRY_COUNT = 200_000
MAX_ASSET_BYTES = 512 * 1024 * 1024
MAX_TOTAL_ASSET_BYTES = 4 * 1024 * 1024 * 1024
MAX_RELATIVE_PATH_BYTES = 4096

DEFAULT_DEADLINE_SECONDS = 45

EXCLUDED_MANIFEST_NAME = "build-manifest.json"

DIRECTORY_OPEN_FLAGS = (
    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK
)
FILE_OPEN_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK

USAGE = (
    "usage: renderer-asset-digest <absolute-renderer-root> "
    "[--test-action <base64-json>] "
    "[--deadline-seconds <positive-integer>]"
)


class RendererDigestFailure(Exception):
    """A clean, expected failure: prints ``str(self)`` to stderr, exit 1."""


class DeadlineExceeded(RendererDigestFailure):
    """Raised by the SIGALRM handler once the overall deadline elapses."""


def digest_failure(message):
    return RendererDigestFailure(message)


class ObservedIdentity:
    """Mirrors Swift's `ObservedIdentity`: dev+inode+size+mtime+ctime+type.

    Two identities are only "fully" equal (`==`) if every one of these
    fields matches - this is what every *after-the-fact* mutation check in
    this file uses, so an in-place truncate-and-rewrite that keeps the same
    inode is still detected via its changed size/mtime/ctime. `is_same_object`
    compares only device+inode - the narrower check used when confirming a
    just-opened descriptor really is the same filesystem object a
    concurrent, separate named lookup just observed.
    """

    __slots__ = (
        "device",
        "inode",
        "size",
        "mtime_seconds",
        "mtime_nanoseconds",
        "ctime_seconds",
        "ctime_nanoseconds",
        "is_directory",
        "is_regular_file",
        "is_symlink",
    )

    def __init__(self, st):
        self.device = st.st_dev
        self.inode = st.st_ino
        self.size = st.st_size
        # st_mtime_ns / st_ctime_ns are always populated by CPython even
        # when the platform stat structure's nanosecond fields are absent
        # (falling back to whole-second precision) - never raise on a
        # missing field the way reading raw C struct members might.
        self.mtime_seconds, self.mtime_nanoseconds = divmod(st.st_mtime_ns, 1_000_000_000)
        self.ctime_seconds, self.ctime_nanoseconds = divmod(st.st_ctime_ns, 1_000_000_000)
        mode = st.st_mode
        self.is_directory = stat.S_ISDIR(mode)
        self.is_regular_file = stat.S_ISREG(mode)
        self.is_symlink = stat.S_ISLNK(mode)

    def is_same_object(self, other):
        return self.device == other.device and self.inode == other.inode

    def __eq__(self, other):
        if not isinstance(other, ObservedIdentity):
            return NotImplemented
        return (
            self.device == other.device
            and self.inode == other.inode
            and self.size == other.size
            and self.mtime_seconds == other.mtime_seconds
            and self.mtime_nanoseconds == other.mtime_nanoseconds
            and self.ctime_seconds == other.ctime_seconds
            and self.ctime_nanoseconds == other.ctime_nanoseconds
            and self.is_directory == other.is_directory
            and self.is_regular_file == other.is_regular_file
            and self.is_symlink == other.is_symlink
        )


class DirectoryRecord:
    __slots__ = ("fd", "parent_index", "name", "relative_path", "identity", "belongs_to_renderer")

    def __init__(self, fd, parent_index, name, relative_path, identity, belongs_to_renderer):
        self.fd = fd
        self.parent_index = parent_index
        self.name = name
        self.relative_path = relative_path
        self.identity = identity
        self.belongs_to_renderer = belongs_to_renderer


class AssetRecord:
    __slots__ = ("fd", "parent_directory_index", "name", "relative_path", "identity")

    def __init__(self, fd, parent_directory_index, name, relative_path, identity):
        self.fd = fd
        self.parent_directory_index = parent_directory_index
        self.name = name
        self.relative_path = relative_path
        self.identity = identity


class CollectionBudget:
    __slots__ = ("entry_count", "total_bytes")

    def __init__(self):
        self.entry_count = 0
        self.total_bytes = 0


class DescriptorPool:
    """Retains every opened descriptor until `close_all` runs (in reverse
    acquisition order, mirroring Swift's own `DescriptorPool`), regardless
    of how the computation exits - see the `finally` in
    `compute_asset_hashes`."""

    def __init__(self):
        self._descriptors = []

    def retain(self, fd):
        self._descriptors.append(fd)

    def close_all(self):
        for fd in reversed(self._descriptors):
            try:
                os.close(fd)
            except OSError:
                pass
        self._descriptors.clear()


def canonical_sort_key(path):
    """Byte-wise UTF-8 ordering shared with `compareRendererAssetPaths` in
    `renderer-build-identity.mjs` and the deleted Swift helper's
    `canonicalPathPrecedes`: no locale collation, case folding, or Unicode
    normalization. Python's own `bytes` comparison is already an unsigned,
    byte-by-byte lexicographic order with a strict prefix sorting first -
    exactly this contract - so encoding to UTF-8 and letting `sorted()`
    compare the resulting `bytes` objects needs no hand-rolled comparator.
    """
    return path.encode("utf-8")


def system_error(context, os_error):
    return digest_failure("{}: {}".format(context, os_error.strerror or os_error))


def inspect_fd(fd, context):
    try:
        st = os.fstat(fd)
    except OSError as error:
        raise system_error("unable to inspect {}".format(context), error) from error
    return ObservedIdentity(st)


def inspect_named_entry(parent_fd, name, context):
    try:
        st = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except OSError as error:
        raise system_error(
            "unable to inspect {} without following symlinks".format(context), error
        ) from error
    return ObservedIdentity(st)


def open_root_directory(parent_fd, name, absolute_path):
    named_identity = inspect_named_entry(
        parent_fd, name, "renderer root directory {}".format(absolute_path)
    )
    if named_identity.is_symlink:
        raise digest_failure("renderer root must not contain a symlink: {}".format(absolute_path))
    if not named_identity.is_directory:
        raise digest_failure("renderer root must be a directory: {}".format(absolute_path))
    try:
        fd = os.open(name, DIRECTORY_OPEN_FLAGS, dir_fd=parent_fd)
    except OSError as error:
        if error.errno == errno.ELOOP:
            raise digest_failure(
                "renderer root must not contain a symlink: {}".format(absolute_path)
            ) from error
        raise system_error(
            "unable to open renderer root directory without following symlinks: {}".format(
                absolute_path
            ),
            error,
        ) from error
    try:
        identity = inspect_fd(fd, "renderer root directory {}".format(absolute_path))
        if not (identity.is_directory and identity.is_same_object(named_identity)):
            raise digest_failure(
                "renderer root changed identity while being opened: {}".format(absolute_path)
            )
        return fd, identity
    except Exception:
        os.close(fd)
        raise


def try_open_asset_directory(parent_fd, name, relative_path):
    named_identity = inspect_named_entry(
        parent_fd, name, "renderer asset {}".format(relative_path)
    )
    if named_identity.is_symlink or not named_identity.is_directory:
        return None
    try:
        fd = os.open(name, DIRECTORY_OPEN_FLAGS, dir_fd=parent_fd)
    except OSError as error:
        if error.errno == errno.ELOOP:
            raise digest_failure(
                "renderer asset directory must not be a symlink: {}".format(relative_path)
            ) from error
        raise system_error(
            "unable to open renderer asset directory without following symlinks: {}".format(
                relative_path
            ),
            error,
        ) from error
    try:
        identity = inspect_fd(fd, "renderer asset directory {}".format(relative_path))
        if not (identity.is_directory and identity.is_same_object(named_identity)):
            raise digest_failure(
                "renderer asset directory changed identity while being opened: {}".format(
                    relative_path
                )
            )
        return fd, identity
    except Exception:
        os.close(fd)
        raise


def open_asset_file(parent_fd, name, relative_path):
    named_identity = inspect_named_entry(
        parent_fd, name, "renderer asset {}".format(relative_path)
    )
    if named_identity.is_symlink:
        raise digest_failure("renderer asset must not be a symlink: {}".format(relative_path))
    try:
        fd = os.open(name, FILE_OPEN_FLAGS, dir_fd=parent_fd)
    except OSError as error:
        if error.errno == errno.ELOOP:
            raise digest_failure(
                "renderer asset must not be a symlink: {}".format(relative_path)
            ) from error
        raise system_error(
            "unable to open renderer asset without following symlinks: {}".format(relative_path),
            error,
        ) from error
    try:
        identity = inspect_fd(fd, "renderer asset {}".format(relative_path))
        if not identity.is_regular_file:
            raise digest_failure(
                "renderer asset must be a regular file after opening: {}".format(relative_path)
            )
        if not identity.is_same_object(named_identity):
            raise digest_failure(
                "renderer asset changed identity while being opened: {}".format(relative_path)
            )
        return fd, identity
    except Exception:
        os.close(fd)
        raise


def directory_entry_names(directory):
    identity = inspect_fd(
        directory.fd, "renderer asset directory {}".format(directory.relative_path)
    )
    if not (identity.is_directory and identity.is_same_object(directory.identity)):
        raise digest_failure(
            "renderer asset directory changed identity while being collected: {}".format(
                directory.relative_path
            )
        )

    # Explicitly `dup()` before listing, exactly mirroring the Swift
    # helper's own manual `Darwin.dup` + `fdopendir`, rather than relying on
    # `os.scandir` accepting (and, per CPython's own implementation, never
    # closing) a bare fd directly. Both behaviors have been verified
    # empirically on this platform's Python 3, but the explicit duplicate
    # keeps this module's own intent self-documenting and independent of
    # that undocumented, version-specific guarantee: `directory.fd` itself
    # is never at risk of being closed by listing it.
    try:
        duplicate_fd = os.dup(directory.fd)
    except OSError as error:
        raise system_error(
            "unable to duplicate renderer asset directory descriptor: {}".format(
                directory.relative_path
            ),
            error,
        ) from error

    # `os.scandir`, unlike `os.listdir`, hands entries back one at a time
    # from an incremental `readdir`-backed iterator instead of eagerly
    # reading and materializing the *entire* directory into one Python list
    # before this function gets to look at a single name. That laziness is
    # what makes the bound below a real, enforced-*during*-enumeration limit
    # rather than an after-the-fact check on a list that was already fully
    # built: a directory containing millions of entries is rejected right
    # after the (MAX_ENTRY_COUNT + 1)th one is read, never after every one
    # of them has already been pulled off disk and held in memory. Only the
    # bounded list actually collected is ever passed to `sorted()`.
    #
    # This is deliberately a *local*, single-directory bound - independent
    # of, and strictly earlier-firing than, `collect_assets`'s own global
    # `budget.entry_count` bound below, which still separately catches many
    # directories each under this local bound cumulatively exceeding
    # `MAX_ENTRY_COUNT` across the whole renderer tree. A single directory
    # that by itself exceeds `MAX_ENTRY_COUNT` necessarily also exceeds that
    # global bound, so both bounds reject with the identical message; this
    # one simply never lets such a directory's entries be fully read and
    # sorted first.
    names = []
    try:
        with os.scandir(duplicate_fd) as entries:
            for entry in entries:
                if len(names) >= MAX_ENTRY_COUNT:
                    raise digest_failure(
                        "renderer asset collection exceeds the maximum entry count of {}".format(
                            MAX_ENTRY_COUNT
                        )
                    )
                names.append(entry.name)
    except OSError as error:
        raise system_error(
            "unable to enumerate renderer asset directory: {}".format(directory.relative_path),
            error,
        ) from error
    finally:
        os.close(duplicate_fd)
    return sorted(names, key=canonical_sort_key)


def collect_assets(directory_index, relative_prefix, directories, assets, pool, budget):
    parent = directories[directory_index]
    for name in directory_entry_names(parent):
        relative_path = "{}/{}".format(relative_prefix, name) if relative_prefix else name
        if relative_path == EXCLUDED_MANIFEST_NAME:
            continue

        if len(relative_path.encode("utf-8")) > MAX_RELATIVE_PATH_BYTES:
            raise digest_failure(
                "renderer asset path exceeds the maximum length of {} bytes: {}...".format(
                    MAX_RELATIVE_PATH_BYTES, relative_path[:200]
                )
            )
        budget.entry_count += 1
        if budget.entry_count > MAX_ENTRY_COUNT:
            raise digest_failure(
                "renderer asset collection exceeds the maximum entry count of {}".format(
                    MAX_ENTRY_COUNT
                )
            )

        opened_directory = try_open_asset_directory(parent.fd, name, relative_path)
        if opened_directory is not None:
            fd, identity = opened_directory
            pool.retain(fd)
            child_index = len(directories)
            directories.append(
                DirectoryRecord(
                    fd=fd,
                    parent_index=directory_index,
                    name=name,
                    relative_path=relative_path,
                    identity=identity,
                    belongs_to_renderer=True,
                )
            )
            collect_assets(child_index, relative_path, directories, assets, pool, budget)
            continue

        fd, identity = open_asset_file(parent.fd, name, relative_path)
        pool.retain(fd)
        if identity.size > MAX_ASSET_BYTES:
            raise digest_failure(
                "renderer asset exceeds the maximum size of {} bytes: {}".format(
                    MAX_ASSET_BYTES, relative_path
                )
            )
        budget.total_bytes += identity.size
        if budget.total_bytes > MAX_TOTAL_ASSET_BYTES:
            raise digest_failure(
                "renderer asset collection exceeds the maximum total size of {} bytes".format(
                    MAX_TOTAL_ASSET_BYTES
                )
            )
        assets.append(
            AssetRecord(
                fd=fd,
                parent_directory_index=directory_index,
                name=name,
                relative_path=relative_path,
                identity=identity,
            )
        )


def verify_root_bindings(directories, root_index):
    if root_index <= 0:
        return
    for index in range(1, root_index + 1):
        directory = directories[index]
        if directory.parent_index is None:
            raise digest_failure("renderer root descriptor hierarchy is incomplete")
        parent = directories[directory.parent_index]
        absolute_path = directory.relative_path
        fd, identity = open_root_directory(parent.fd, directory.name, absolute_path)
        try:
            if not (identity.is_directory and identity.is_same_object(directory.identity)):
                raise digest_failure(
                    "renderer root changed identity while hashing: {}".format(absolute_path)
                )
        finally:
            os.close(fd)


def verify_asset_directory_binding(directory, parent):
    named_identity = inspect_named_entry(
        parent.fd, directory.name, "renderer asset directory {}".format(directory.relative_path)
    )
    if named_identity.is_symlink:
        raise digest_failure(
            "renderer asset directory must not be a symlink: {}".format(directory.relative_path)
        )
    opened = try_open_asset_directory(parent.fd, directory.name, directory.relative_path)
    if opened is None:
        raise digest_failure(
            "renderer asset directory changed identity while being opened: {}".format(
                directory.relative_path
            )
        )
    fd, identity = opened
    try:
        if not (identity.is_directory and identity.is_same_object(directory.identity)):
            raise digest_failure(
                "renderer asset directory changed identity while being opened: {}".format(
                    directory.relative_path
                )
            )
    finally:
        os.close(fd)


def verify_asset_file_binding(asset, parent):
    fd, identity = open_asset_file(parent.fd, asset.name, asset.relative_path)
    try:
        if not (identity.is_regular_file and identity == asset.identity):
            raise digest_failure(
                "renderer asset changed identity while being opened: {}".format(
                    asset.relative_path
                )
            )
    finally:
        os.close(fd)


def verify_pinned_descriptors(directories, root_index, assets):
    verify_root_bindings(directories, root_index)

    for directory in directories:
        if (
            directory.belongs_to_renderer
            and directory.parent_index is not None
            and directory.relative_path != "/"
        ):
            verify_asset_directory_binding(directory, directories[directory.parent_index])
    for asset in assets:
        verify_asset_file_binding(asset, directories[asset.parent_directory_index])

    for directory in directories:
        if directory.belongs_to_renderer:
            current = inspect_fd(
                directory.fd, "renderer asset directory {}".format(directory.relative_path)
            )
            if not (current.is_directory and current == directory.identity):
                raise digest_failure(
                    "renderer asset directory changed identity while hashing: {}".format(
                        directory.relative_path
                    )
                )
    for asset in assets:
        current = inspect_fd(asset.fd, "renderer asset {}".format(asset.relative_path))
        if not (current.is_regular_file and current == asset.identity):
            raise digest_failure(
                "renderer asset changed identity while being opened: {}".format(
                    asset.relative_path
                )
            )


def sha256_of_descriptor(fd, relative_path, expected):
    try:
        os.lseek(fd, 0, os.SEEK_SET)
    except OSError as error:
        raise system_error("unable to seek renderer asset: {}".format(relative_path), error) from error

    hasher = hashlib.sha256()
    while True:
        try:
            chunk = os.read(fd, 64 * 1024)
        except InterruptedError:
            # CPython (PEP 475) already auto-retries a bare EINTR for us;
            # this only ever fires if some *other*, non-raising signal
            # handler is installed - our own SIGALRM deadline handler
            # always raises, so it is never swallowed here.
            continue
        except OSError as error:
            raise system_error(
                "unable to read renderer asset: {}".format(relative_path), error
            ) from error
        if not chunk:
            break
        hasher.update(chunk)

    after_read = inspect_fd(fd, "renderer asset {}".format(relative_path))
    if not (after_read.is_regular_file and after_read == expected):
        raise digest_failure("renderer asset changed while hashing: {}".format(relative_path))
    return hasher.hexdigest()


# ---------------------------------------------------------------------------
# Declarative, in-process test actions. `--test-action` is test-only
# (production never supplies one, and `run_test_action` never runs unless a
# test explicitly asked for one, via the CLI, exactly like every existing
# production invocation) and deliberately closed: `_TEST_ACTIONS` below is
# the exhaustive set of actions any test may ever request, each a plain,
# synchronous filesystem call this same process makes directly - never a
# subprocess, never a new process/session/process group. There is
# accordingly nothing here for the overall SIGALRM deadline (`_on_alarm`/
# `main` below) to separately reach into and clean up: an action either
# finishes well within that deadline or, for `delay`, is itself interrupted
# by the very same alarm-raised `DeadlineExceeded` that would interrupt any
# other blocking call in this file, at whatever point `time.sleep` happens
# to be. This is the one narrow test seam a prior, deleted design instead
# built out of an arbitrary externally-supplied executable running in its
# own process group - a shape that could never fully guarantee every
# descendant a hook chose to spawn (including one that itself called
# `setsid`, detaching from the very process group being torn down) was
# actually reachable for cleanup. A fixed, closed, in-process action
# vocabulary has no such gap: there is never a descendant to lose track of.
_TEST_ACTIONS = {
    "replace-file-with-symlink": 2,
    "replace-file-with-file": 2,
    "replace-file-with-directory": 1,
    "mutate-file": 1,
    "replace-directory-with-symlink": 3,
    "delay": 1,
}


def _decode_test_action(encoded):
    try:
        decoded = base64.b64decode(encoded, validate=True)
        payload = json.loads(decoded.decode("utf-8"))
    except Exception:
        raise digest_failure("test action is invalid") from None
    if (
        not isinstance(payload, dict)
        or not isinstance(payload.get("action"), str)
        or payload["action"] not in _TEST_ACTIONS
        or not isinstance(payload.get("args"), list)
        or len(payload["args"]) != _TEST_ACTIONS[payload["action"]]
        or not all(isinstance(argument, str) for argument in payload["args"])
    ):
        raise digest_failure("test action is invalid")
    return {"action": payload["action"], "args": list(payload["args"])}


def run_test_action(test_action):
    """Performs exactly one narrow, in-process filesystem action between
    asset collection and descriptor re-verification - see the module
    docstring and `_TEST_ACTIONS` above for why this replaces a prior,
    deleted subprocess-hook design. `test_action` is `None` on every
    production invocation (no `--test-action` flag was supplied), in which
    case this is a no-op.
    """
    if test_action is None:
        return
    name = test_action["action"]
    args = test_action["args"]
    if name == "replace-file-with-symlink":
        target, replacement = args
        os.unlink(target)
        os.symlink(replacement, target)
    elif name == "replace-file-with-file":
        replacement, target = args
        os.rename(replacement, target)
    elif name == "replace-file-with-directory":
        (target,) = args
        os.unlink(target)
        os.mkdir(target)
    elif name == "mutate-file":
        (target,) = args
        with open(target, "w") as handle:
            handle.write("in-place mutation after asset collection\n")
    elif name == "replace-directory-with-symlink":
        target, parked, replacement = args
        os.rename(target, parked)
        os.symlink(replacement, target)
    elif name == "delay":
        (seconds,) = args
        time.sleep(float(seconds))
    else:
        # Unreachable: _decode_test_action only ever returns an action name
        # present in _TEST_ACTIONS.
        raise digest_failure("test action is invalid")


def _on_alarm(_signum, _frame):
    raise DeadlineExceeded(
        "descriptor-anchored renderer asset digest helper exceeded its overall deadline"
    )


def _positive_int(raw, flag):
    try:
        value = int(raw, 10)
    except ValueError:
        raise digest_failure("{} must be a positive integer".format(flag)) from None
    if value <= 0:
        raise digest_failure("{} must be a positive integer".format(flag))
    return value


def parse_arguments(argv):
    if not argv:
        raise digest_failure(USAGE)
    root = argv[0]
    if not root.startswith("/"):
        raise digest_failure("renderer root must be an absolute path")

    test_action = None
    deadline_seconds = DEFAULT_DEADLINE_SECONDS
    index = 1
    while index < len(argv):
        flag = argv[index]
        if flag == "--test-action":
            if index + 1 >= len(argv):
                raise digest_failure(USAGE)
            test_action = _decode_test_action(argv[index + 1])
            index += 2
            continue
        if flag == "--deadline-seconds":
            if index + 1 >= len(argv):
                raise digest_failure(USAGE)
            deadline_seconds = _positive_int(argv[index + 1], "--deadline-seconds")
            index += 2
            continue
        raise digest_failure(USAGE)

    return root, test_action, deadline_seconds


def compute_asset_hashes(root_path, test_action):
    components = [component for component in root_path.split("/") if component != ""]
    if any(component in (".", "..") for component in components):
        raise digest_failure("renderer root path is invalid")

    try:
        root_fd = os.open("/", DIRECTORY_OPEN_FLAGS)
    except OSError as error:
        raise system_error("unable to open filesystem root without following symlinks", error) from error

    pool = DescriptorPool()
    pool.retain(root_fd)
    try:
        root_identity = inspect_fd(root_fd, "filesystem root")
        if not root_identity.is_directory:
            raise digest_failure("filesystem root is not a directory")
        directories = [
            DirectoryRecord(
                fd=root_fd,
                parent_index=None,
                name="",
                relative_path="/",
                identity=root_identity,
                belongs_to_renderer=False,
            )
        ]

        path_so_far = ""
        for component in components:
            path_so_far += "/" + component
            parent_index = len(directories) - 1
            fd, identity = open_root_directory(directories[parent_index].fd, component, path_so_far)
            pool.retain(fd)
            directories.append(
                DirectoryRecord(
                    fd=fd,
                    parent_index=parent_index,
                    name=component,
                    relative_path=path_so_far,
                    identity=identity,
                    belongs_to_renderer=False,
                )
            )
        renderer_root_index = len(directories) - 1
        directories[renderer_root_index].belongs_to_renderer = True

        assets = []
        budget = CollectionBudget()
        collect_assets(renderer_root_index, "", directories, assets, pool, budget)

        run_test_action(test_action)
        verify_pinned_descriptors(directories, renderer_root_index, assets)

        hashes = []
        for asset in assets:
            hashes.append(
                {
                    "relativePath": asset.relative_path,
                    "sha256": sha256_of_descriptor(asset.fd, asset.relative_path, asset.identity),
                }
            )
        verify_pinned_descriptors(directories, renderer_root_index, assets)
        hashes.sort(key=lambda entry: canonical_sort_key(entry["relativePath"]))
        return hashes
    finally:
        pool.close_all()


def main():
    root, test_action, deadline_seconds = parse_arguments(sys.argv[1:])

    previous_handler = signal.signal(signal.SIGALRM, _on_alarm)
    signal.alarm(deadline_seconds)
    try:
        hashes = compute_asset_hashes(root, test_action)
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous_handler)

    sys.stdout.write(json.dumps(hashes))
    sys.stdout.write("\n")


if __name__ == "__main__":
    try:
        main()
    except RendererDigestFailure as error:
        sys.stderr.write("{}\n".format(error))
        sys.exit(1)
    except Exception as error:  # noqa: BLE001 - top-level catch-all, mirrors the Swift helper's own.
        sys.stderr.write("renderer asset digest helper failed: {}\n".format(error))
        sys.exit(1)
