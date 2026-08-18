#!/usr/bin/env python3
"""Descriptor-anchored renderer asset traversal/hashing helper.

Ports, byte-for-byte in observable contract, the deleted
`renderer-asset-digest.swift` helper: `scripts/renderer-build-identity.mjs`
reads *this file's own source bytes* fresh from disk and pipes them,
verbatim, to the trusted system interpreter's stdin (`/usr/bin/python3 -`)
- this file is never compiled, never written to a temporary file, and never
executed by a repository-relative pathname. There is accordingly no shared
canonical executable, no cache, no private run directory, and no
publication/execution TOCTOU: the only "artifact" of any invocation is a
single, short-lived `/usr/bin/python3` process that reads its own program
from stdin and exits.

CLI contract (all consumed positionally/by flag, no environment lookups of
its own beyond what CPython itself always honors):

    <absolute-renderer-root>
    [--after-collection-hook <base64-json>]
    [--deadline-seconds <positive-integer>]
    [--hook-timeout-seconds <positive-integer>]

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
import subprocess
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
DEFAULT_HOOK_TIMEOUT_SECONDS = 20

EXCLUDED_MANIFEST_NAME = "build-manifest.json"

DIRECTORY_OPEN_FLAGS = (
    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK
)
FILE_OPEN_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK

USAGE = (
    "usage: renderer-asset-digest <absolute-renderer-root> "
    "[--after-collection-hook <base64-json>] "
    "[--deadline-seconds <positive-integer>] "
    "[--hook-timeout-seconds <positive-integer>]"
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
    # `os.listdir`/`os.scandir` accepting (and, per CPython's own
    # implementation, never closing) a bare fd directly. Both behaviors have
    # been verified empirically on this platform's Python 3, but the
    # explicit duplicate keeps this module's own intent self-documenting
    # and independent of that undocumented, version-specific guarantee:
    # `directory.fd` itself is never at risk of being closed by listing it.
    try:
        duplicate_fd = os.dup(directory.fd)
    except OSError as error:
        raise system_error(
            "unable to duplicate renderer asset directory descriptor: {}".format(
                directory.relative_path
            ),
            error,
        ) from error
    try:
        names = os.listdir(duplicate_fd)
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
# Process-group bounded execution. The optional `--after-collection-hook` is
# test-only (production never supplies one) but must still never be able to
# hang this helper, or this process, forever: it always runs in its own new
# session/process group (`start_new_session=True`), is always waited on with
# a finite timeout, and - on a timeout *or* after any ordinary exit, so a
# hook that itself forked a still-running descendant can never leak one past
# this function returning - is always torn down by signaling its exact
# process group (never a bare PID, which could hit an unrelated, later
# process if the hook's own leader has already exited and that PID been
# recycled) and awaited until it is confirmed gone or a bounded cleanup
# deadline itself elapses.
def _process_group_alive(pgid):
    if not isinstance(pgid, int) or pgid <= 0:
        return False
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        # Mirrors this repository's existing `isProcessGroupAlive` in
        # scripts/build-standalone-renderer.mjs: unable to prove the group
        # is gone is treated as "still alive", never as "assume dead" -
        # retaining caution here is always safer than declaring a
        # potentially-live process stale. In practice this is only ever
        # observed, on this platform, for the brief window in which the
        # hook's own direct process has exited but not yet been reaped by
        # us (a zombie) - `_terminate_process_group` below always polls
        # `process.poll()` (which reaps as a side effect) interleaved with
        # this check specifically to keep that window as short as possible.
        return True


def _signal_process_group(pgid, sig):
    try:
        os.killpg(pgid, sig)
    except (ProcessLookupError, PermissionError):
        pass


def _terminate_process_group(process, label):
    """Terminates the exact process group led by `process` (our own direct
    child, so its own exit is always independently reapable/confirmable via
    `process.poll()`, never only via the group-wide, signal-based
    `_process_group_alive` check). `process.poll()` is deliberately called
    on every single polling iteration below, interleaved with every
    `_process_group_alive` check: reaping our own direct child the instant
    it exits keeps it from lingering as a zombie, which is the one
    condition observed (empirically, on this platform) to make a process
    group's own signal-existence check itself return an ambiguous
    permission error instead of cleanly resolving to alive/dead.
    """
    pgid = process.pid
    process.poll()
    if not _process_group_alive(pgid):
        return
    _signal_process_group(pgid, signal.SIGTERM)
    term_deadline = time.monotonic() + 2.0
    while time.monotonic() < term_deadline:
        process.poll()
        if not _process_group_alive(pgid):
            return
        time.sleep(0.02)
    process.poll()
    if not _process_group_alive(pgid):
        return
    _signal_process_group(pgid, signal.SIGKILL)
    kill_deadline = time.monotonic() + 2.0
    while time.monotonic() < kill_deadline:
        process.poll()
        if not _process_group_alive(pgid):
            return
        time.sleep(0.02)
    process.poll()
    if _process_group_alive(pgid):
        raise digest_failure(
            "{} process group {} remained alive after termination".format(label, pgid)
        )


# Set only while a hook child is actually running, so the top-level SIGALRM
# handler's own defensive cleanup (see `main`) can find and terminate it even
# if the overall deadline fires while `run_hook` is itself blocked inside
# `process.wait(...)` (or inside its own termination polling loop). This is
# deliberately a module-level, not function-local, value, and deliberately
# holds the `Popen` object itself (not just its pid) so that cleanup can
# always interleave reaping (see `_terminate_process_group`) regardless of
# which code path (`run_hook` itself, or `main`'s deadline handler) performs
# it. Once a `DeadlineExceeded` interrupts a blocked wait, it propagates
# straight through `run_hook` (which does not catch it) and unwinds past the
# local frame that would otherwise have cleaned up - only a value that
# survives that unwind lets `main`'s own `except DeadlineExceeded` handler
# still find and terminate the exact process. It is intentionally never
# cleared in a `finally`, only ever explicitly on the ordinary/timeout
# completion paths below and by `main` itself after a deadline-triggered
# cleanup.
_active_hook_process = None


def run_hook(hook, hook_timeout_seconds):
    global _active_hook_process
    if hook is None:
        return

    # Block SIGALRM for the brief window between spawning the hook and
    # recording it as the active hook process: without this, a deadline
    # that fires in that exact window could interrupt us after `Popen` has
    # already created the child but before `_active_hook_process` is set,
    # which would leak the child past `main`'s own cleanup (it can only
    # terminate a process it knows about).
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGALRM})
    try:
        try:
            process = subprocess.Popen(
                [hook["executable"], *hook["args"]],
                start_new_session=True,
            )
        except OSError as error:
            raise digest_failure(
                "renderer asset collection hook failed to start: {}".format(
                    error.strerror or error
                )
            ) from error
        _active_hook_process = process
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)

    # From here on, a `DeadlineExceeded` raised by the alarm handler is
    # allowed to interrupt `wait()` (or the termination poll below) and
    # propagate immediately - `_active_hook_process` stays set for `main`
    # to find in that case, so nothing is left uncleaned.
    timed_out = False
    try:
        process.wait(timeout=hook_timeout_seconds)
    except subprocess.TimeoutExpired:
        timed_out = True

    # Always reconcile the process group afterward - even a hook that
    # exited normally and promptly may have left a background descendant of
    # its own still running - never only on the timeout path.
    _terminate_process_group(process, "renderer asset collection hook")
    if process.poll() is None:
        process.wait()
    _active_hook_process = None

    if timed_out:
        raise digest_failure(
            "renderer asset collection hook did not finish within {}s and was killed".format(
                hook_timeout_seconds
            )
        )
    if process.returncode != 0:
        raise digest_failure("renderer asset collection hook failed")


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


def _decode_hook(encoded):
    try:
        decoded = base64.b64decode(encoded, validate=True)
        payload = json.loads(decoded.decode("utf-8"))
    except Exception:
        raise digest_failure("renderer asset collection hook is invalid") from None
    if (
        not isinstance(payload, dict)
        or not isinstance(payload.get("executable"), str)
        or not payload["executable"]
        or not isinstance(payload.get("args"), list)
        or not all(isinstance(argument, str) for argument in payload["args"])
    ):
        raise digest_failure("renderer asset collection hook is invalid")
    return {"executable": payload["executable"], "args": list(payload["args"])}


def parse_arguments(argv):
    if not argv:
        raise digest_failure(USAGE)
    root = argv[0]
    if not root.startswith("/"):
        raise digest_failure("renderer root must be an absolute path")

    hook = None
    deadline_seconds = DEFAULT_DEADLINE_SECONDS
    hook_timeout_seconds = DEFAULT_HOOK_TIMEOUT_SECONDS
    index = 1
    while index < len(argv):
        flag = argv[index]
        if flag == "--after-collection-hook":
            if index + 1 >= len(argv):
                raise digest_failure(USAGE)
            hook = _decode_hook(argv[index + 1])
            index += 2
            continue
        if flag == "--deadline-seconds":
            if index + 1 >= len(argv):
                raise digest_failure(USAGE)
            deadline_seconds = _positive_int(argv[index + 1], "--deadline-seconds")
            index += 2
            continue
        if flag == "--hook-timeout-seconds":
            if index + 1 >= len(argv):
                raise digest_failure(USAGE)
            hook_timeout_seconds = _positive_int(argv[index + 1], "--hook-timeout-seconds")
            index += 2
            continue
        raise digest_failure(USAGE)

    # No relationship between `hook_timeout_seconds` and `deadline_seconds`
    # is enforced here: the overall deadline must remain free to act as a
    # true backstop that can preempt and clean up a hook even if the hook's
    # own timeout is (mis)configured longer than the deadline, or has not
    # yet elapsed - see `run_hook` and `main`'s `DeadlineExceeded` handling.
    return root, hook, deadline_seconds, hook_timeout_seconds


def compute_asset_hashes(root_path, hook, hook_timeout_seconds):
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

        run_hook(hook, hook_timeout_seconds)
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
    root, hook, deadline_seconds, hook_timeout_seconds = parse_arguments(sys.argv[1:])

    previous_handler = signal.signal(signal.SIGALRM, _on_alarm)
    signal.alarm(deadline_seconds)
    try:
        hashes = compute_asset_hashes(root, hook, hook_timeout_seconds)
    except DeadlineExceeded:
        if _active_hook_process is not None:
            _terminate_process_group(_active_hook_process, "renderer asset collection hook")
        raise
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
