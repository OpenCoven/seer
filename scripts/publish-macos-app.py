#!/usr/bin/env python3
"""Copy and atomically publish Seer.app without following output-path symlinks."""

import argparse
import fcntl
import hashlib
import json
import os
import re
import secrets
import signal
import stat
import subprocess
import sys


O_NOFOLLOW = getattr(os, "O_NOFOLLOW", None)
if O_NOFOLLOW is None:
    raise RuntimeError("publish-macos-app.py requires O_NOFOLLOW")

DIRECTORY_OPEN_FLAGS = os.O_RDONLY | os.O_DIRECTORY | O_NOFOLLOW
PROVENANCE_FILE = "standalone-build-provenance.json"
PUBLICATION_LOCK_FILE = ".seer-publication.lock"
TRANSACTION_JOURNAL_FILE = ".seer-publication-transaction.json"
TRANSACTION_JOURNAL_TEMP_FILE = ".seer-publication-transaction.new"
TRANSACTION_JOURNAL_SCHEMA_VERSION = 1
TRANSACTION_JOURNAL_MAX_BYTES = 64 * 1024
PROVENANCE_SCHEMA_VERSION = 2
PROVENANCE_ALGORITHM = "sha256"
TRANSACTION_PHASES = {
    "staging",
    "prepared",
    "app-backed-up",
    "provenance-backed-up",
    "app-published",
    "pair-published",
    "cleanup",
    "rolling-back",
}
STAGE_NAME_PATTERN = re.compile(r"\.seer-stage-[0-9a-f]{32}\Z")
APP_BACKUP_NAME_PATTERN = re.compile(r"\.seer-backup-[0-9a-f]{32}\Z")
PROVENANCE_TEMP_NAME_PATTERN = re.compile(r"\.seer-provenance-[0-9a-f]{32}\.json\Z")
PROVENANCE_BACKUP_NAME_PATTERN = re.compile(
    r"\.seer-provenance-backup-[0-9a-f]{32}\.json\Z"
)


class PublicationError(RuntimeError):
    pass


class DeferredSignal(BaseException):
    def __init__(self, signal_number):
        super().__init__("interrupted by {}".format(signal.Signals(signal_number).name))
        self.signal_number = signal_number


class SignalDeferral:
    def __init__(self):
        self.pending_signal = None
        self.previous_handlers = {}

    def _handle(self, signal_number, _frame):
        if self.pending_signal is None:
            self.pending_signal = signal_number

    def install(self):
        for signal_number in (signal.SIGINT, signal.SIGTERM):
            self.previous_handlers[signal_number] = signal.getsignal(signal_number)
            signal.signal(signal_number, self._handle)

    def restore(self):
        for signal_number, handler in self.previous_handlers.items():
            signal.signal(signal_number, handler)
        self.previous_handlers.clear()

    def raise_if_pending(self):
        if self.pending_signal is not None:
            raise DeferredSignal(self.pending_signal)


def identity(info):
    return (info.st_dev, info.st_ino)


def describe(path, info):
    return "{} (device {}, inode {})".format(path, info.st_dev, info.st_ino)


def lstat_at(parent_fd, name):
    try:
        return os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        return None


def require_owned_directory(info, label):
    if stat.S_ISLNK(info.st_mode):
        raise PublicationError("{} is a symlink; refusing to follow it".format(label))
    if not stat.S_ISDIR(info.st_mode):
        raise PublicationError("{} is not a directory".format(label))
    if info.st_uid != os.geteuid():
        raise PublicationError("{} is not owned by uid {}".format(label, os.geteuid()))


def open_checked_directory_at(parent_fd, name, label, create=False, mode=0o755):
    before = lstat_at(parent_fd, name)
    if before is None:
        if not create:
            raise PublicationError("{} disappeared".format(label))
        try:
            os.mkdir(name, mode=mode, dir_fd=parent_fd)
        except FileExistsError:
            pass
        before = lstat_at(parent_fd, name)
    if before is None:
        raise PublicationError("{} could not be created".format(label))
    require_owned_directory(before, label)

    try:
        opened_fd = os.open(name, DIRECTORY_OPEN_FLAGS, dir_fd=parent_fd)
    except OSError as error:
        raise PublicationError("unable to open {} without following links: {}".format(label, error))
    after = os.fstat(opened_fd)
    try:
        require_owned_directory(after, label)
        if identity(before) != identity(after):
            raise PublicationError("{} changed identity while it was opened".format(label))
    except Exception:
        os.close(opened_fd)
        raise
    return opened_fd, after


def open_repo_root(repo_root):
    if not os.path.isabs(repo_root):
        raise PublicationError("repo root must be absolute")
    normalized = os.path.normpath(repo_root)
    canonical = os.path.realpath(normalized)
    if canonical != normalized:
        raise PublicationError("repo root must already be canonical: {} resolves to {}".format(repo_root, canonical))

    before = os.lstat(normalized)
    require_owned_directory(before, "repository root")
    try:
        repo_fd = os.open(normalized, DIRECTORY_OPEN_FLAGS)
    except OSError as error:
        raise PublicationError("unable to open repository root without following links: {}".format(error))
    after = os.fstat(repo_fd)
    try:
        require_owned_directory(after, "repository root")
        if identity(before) != identity(after):
            raise PublicationError("repository root changed identity while it was opened")
    except Exception:
        os.close(repo_fd)
        raise
    return repo_fd, after


def open_output_chain(repo_fd, create):
    descriptors = []
    parent_fd = repo_fd
    for name, label in (
        ("build", "repository build directory"),
        ("macos", "macOS build directory"),
        ("unsigned", "unsigned output directory"),
    ):
        opened_fd, info = open_checked_directory_at(parent_fd, name, label, create=create)
        descriptors.append((opened_fd, info))
        parent_fd = opened_fd
    return descriptors


def verify_identity(actual, expected, label):
    if identity(actual) != identity(expected):
        raise PublicationError(
            "{} changed identity: expected {}, found {}".format(
                label,
                describe(label, expected),
                describe(label, actual),
            )
        )


def reopen_and_verify_output_chain(repo_root, expected_repo, expected_chain):
    repo_fd, repo_info = open_repo_root(repo_root)
    try:
        verify_identity(repo_info, expected_repo, "repository root")
        chain = open_output_chain(repo_fd, create=False)
        try:
            labels = ("repository build directory", "macOS build directory", "unsigned output directory")
            for (_, actual), (_, expected), label in zip(chain, expected_chain, labels):
                verify_identity(actual, expected, label)
        except Exception:
            for descriptor, _ in reversed(chain):
                os.close(descriptor)
            raise
        return repo_fd, chain
    except Exception:
        os.close(repo_fd)
        raise


def copy_regular_file(source_fd, destination_fd, name, source_info, copy_hook=None):
    source_file = os.open(name, os.O_RDONLY | O_NOFOLLOW, dir_fd=source_fd)
    try:
        verify_identity(os.fstat(source_file), source_info, "source file {}".format(name))
        destination_file = os.open(
            name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | O_NOFOLLOW,
            stat.S_IMODE(source_info.st_mode),
            dir_fd=destination_fd,
        )
        try:
            if copy_hook is not None:
                copy_hook()
            while True:
                chunk = os.read(source_file, 1024 * 1024)
                if not chunk:
                    break
                offset = 0
                while offset < len(chunk):
                    offset += os.write(destination_file, chunk[offset:])
            os.fchmod(destination_file, stat.S_IMODE(source_info.st_mode))
            os.fsync(destination_file)
        finally:
            os.close(destination_file)
    finally:
        os.close(source_file)


def copy_tree_contents(source_fd, destination_fd, copy_hook=None):
    for name in os.listdir(source_fd):
        source_info = lstat_at(source_fd, name)
        if source_info is None:
            raise PublicationError("source entry {!r} disappeared during copy".format(name))
        if stat.S_ISLNK(source_info.st_mode):
            raise PublicationError("source entry {!r} is a symlink; bundle copies never follow symlinks".format(name))
        if stat.S_ISREG(source_info.st_mode):
            copy_regular_file(source_fd, destination_fd, name, source_info, copy_hook)
            continue
        if stat.S_ISDIR(source_info.st_mode):
            os.mkdir(name, mode=0o700, dir_fd=destination_fd)
            source_child, _ = open_checked_directory_at(
                source_fd,
                name,
                "source directory {}".format(name),
            )
            destination_child, _ = open_checked_directory_at(
                destination_fd,
                name,
                "staged directory {}".format(name),
            )
            try:
                copy_tree_contents(source_child, destination_child, copy_hook)
                os.fchmod(destination_child, stat.S_IMODE(source_info.st_mode))
                os.fsync(destination_child)
            finally:
                os.close(destination_child)
                os.close(source_child)
            continue
        raise PublicationError("source entry {!r} is neither a regular file nor a directory".format(name))


def stage_source_app(source_app, unsigned_fd, stage_name, copy_hook=None):
    source_before = os.lstat(source_app)
    if stat.S_ISLNK(source_before.st_mode) or not stat.S_ISDIR(source_before.st_mode):
        raise PublicationError("source app must be a real directory, not a symlink")
    source_fd = os.open(source_app, DIRECTORY_OPEN_FLAGS)
    source_after = os.fstat(source_fd)
    try:
        verify_identity(source_after, source_before, "source app")
        os.mkdir(stage_name, mode=0o700, dir_fd=unsigned_fd)
        stage_fd, stage_info = open_checked_directory_at(
            unsigned_fd,
            stage_name,
            "private staging directory",
        )
        try:
            os.mkdir("Seer.app", mode=0o700, dir_fd=stage_fd)
            staged_app_fd, staged_app_info = open_checked_directory_at(
                stage_fd,
                "Seer.app",
                "staged Seer.app",
            )
            try:
                copy_tree_contents(source_fd, staged_app_fd, copy_hook)
                os.fchmod(staged_app_fd, stat.S_IMODE(source_before.st_mode))
                os.fsync(staged_app_fd)
            finally:
                os.close(staged_app_fd)
            os.fsync(stage_fd)
            return stage_name, stage_fd, stage_info, staged_app_info
        except BaseException:
            os.close(stage_fd)
            raise
    finally:
        os.close(source_fd)


def write_provenance_temp(
    macos_fd,
    temp_name,
    canonical_repo_root,
    effective_derived_data_path,
    app_digest,
):
    payload = {
        "schemaVersion": PROVENANCE_SCHEMA_VERSION,
        "algorithm": PROVENANCE_ALGORITHM,
        "canonicalRepoRoot": canonical_repo_root,
        "effectiveDerivedDataPath": effective_derived_data_path,
        "appDigest": app_digest,
        "generation": app_digest,
    }
    encoded = (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode("utf-8")
    descriptor = os.open(
        temp_name,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | O_NOFOLLOW,
        0o600,
        dir_fd=macos_fd,
    )
    try:
        offset = 0
        while offset < len(encoded):
            offset += os.write(descriptor, encoded[offset:])
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    return temp_name


def sha256_file_at(parent_fd, name, expected):
    descriptor = os.open(name, os.O_RDONLY | O_NOFOLLOW, dir_fd=parent_fd)
    try:
        verify_identity(os.fstat(descriptor), expected, "app digest file {}".format(name))
        digest = hashlib.sha256()
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
        return digest.hexdigest()
    finally:
        os.close(descriptor)


def collect_app_digest_lines(directory_fd, prefix, lines):
    for name in sorted(os.listdir(directory_fd), key=lambda value: value.encode("utf-8")):
        info = lstat_at(directory_fd, name)
        if info is None:
            raise PublicationError("app digest entry {!r} disappeared".format(name))
        relative_path = "{}/{}".format(prefix, name) if prefix else name
        if stat.S_ISLNK(info.st_mode):
            raise PublicationError("app digest entry {!r} is a symlink".format(relative_path))
        if stat.S_ISREG(info.st_mode):
            lines.append("{}:{}\n".format(relative_path, sha256_file_at(directory_fd, name, info)))
            continue
        if stat.S_ISDIR(info.st_mode):
            child_fd, _ = open_checked_directory_at(
                directory_fd,
                name,
                "app digest directory {}".format(relative_path),
            )
            try:
                collect_app_digest_lines(child_fd, relative_path, lines)
            finally:
                os.close(child_fd)
            continue
        raise PublicationError("app digest entry {!r} is not a regular file or directory".format(relative_path))


def compute_staged_app_digest(stage_fd):
    app_fd, _ = open_checked_directory_at(stage_fd, "Seer.app", "staged Seer.app")
    try:
        lines = []
        collect_app_digest_lines(app_fd, "", lines)
        return hashlib.sha256("".join(lines).encode("utf-8")).hexdigest()
    finally:
        os.close(app_fd)


def validate_staged_architecture(stage_fd, unsigned_path, stage_name):
    app_fd, _ = open_checked_directory_at(stage_fd, "Seer.app", "staged Seer.app")
    contents_fd = None
    macos_fd = None
    try:
        contents_fd, _ = open_checked_directory_at(app_fd, "Contents", "staged app Contents")
        macos_fd, _ = open_checked_directory_at(contents_fd, "MacOS", "staged app MacOS")
        executable_info = lstat_at(macos_fd, "Seer")
        if executable_info is None or stat.S_ISLNK(executable_info.st_mode) or not stat.S_ISREG(executable_info.st_mode):
            raise PublicationError("staged executable must be a regular non-symlink file")
        executable_fd = os.open("Seer", os.O_RDONLY | O_NOFOLLOW, dir_fd=macos_fd)
        try:
            verify_identity(os.fstat(executable_fd), executable_info, "staged executable")
        finally:
            os.close(executable_fd)

        executable_path = os.path.join(unsigned_path, stage_name, "Seer.app", "Contents", "MacOS", "Seer")
        result = subprocess.run(
            ["/usr/bin/lipo", "-archs", executable_path],
            check=True,
            capture_output=True,
            text=True,
        )
        executable_after = lstat_at(macos_fd, "Seer")
        if executable_after is None:
            raise PublicationError("staged executable disappeared while lipo inspected it")
        verify_identity(executable_after, executable_info, "staged executable after lipo")
        architectures = result.stdout.strip()
        if architectures != "arm64":
            raise PublicationError(
                "expected /usr/bin/lipo -archs for the private staged executable to equal exactly "
                "'arm64'; got {!r}".format(architectures)
            )
    finally:
        if macos_fd is not None:
            os.close(macos_fd)
        if contents_fd is not None:
            os.close(contents_fd)
        os.close(app_fd)


def acquire_publication_lock(macos_fd):
    before = lstat_at(macos_fd, PUBLICATION_LOCK_FILE)
    if before is None:
        try:
            descriptor = os.open(
                PUBLICATION_LOCK_FILE,
                os.O_RDWR | os.O_CREAT | os.O_EXCL | O_NOFOLLOW,
                0o600,
                dir_fd=macos_fd,
            )
        except FileExistsError:
            descriptor = os.open(PUBLICATION_LOCK_FILE, os.O_RDWR | O_NOFOLLOW, dir_fd=macos_fd)
    else:
        if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
            raise PublicationError("publication lock must be a regular non-symlink file")
        descriptor = os.open(PUBLICATION_LOCK_FILE, os.O_RDWR | O_NOFOLLOW, dir_fd=macos_fd)
    try:
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode) or opened.st_uid != os.geteuid():
            raise PublicationError("publication lock must be a regular file owned by the current uid")
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        current = lstat_at(macos_fd, PUBLICATION_LOCK_FILE)
        if current is None:
            raise PublicationError("publication lock disappeared after acquisition")
        verify_identity(current, opened, "publication lock")
        return descriptor
    except Exception:
        os.close(descriptor)
        raise


def unlink_verified(parent_fd, name, expected):
    current = lstat_at(parent_fd, name)
    if current is None:
        raise PublicationError("{} disappeared before cleanup".format(name))
    verify_identity(current, expected, "cleanup entry {}".format(name))
    os.unlink(name, dir_fd=parent_fd)


def remove_tree_verified(parent_fd, name, expected):
    current = lstat_at(parent_fd, name)
    if current is None:
        raise PublicationError("{} disappeared before cleanup".format(name))
    verify_identity(current, expected, "cleanup entry {}".format(name))

    if not stat.S_ISDIR(current.st_mode):
        unlink_verified(parent_fd, name, current)
        return

    directory_fd = os.open(name, DIRECTORY_OPEN_FLAGS, dir_fd=parent_fd)
    try:
        verify_identity(os.fstat(directory_fd), current, "cleanup directory {}".format(name))
        for child_name in os.listdir(directory_fd):
            child_info = lstat_at(directory_fd, child_name)
            if child_info is None:
                raise PublicationError("cleanup entry {} disappeared".format(child_name))
            if stat.S_ISDIR(child_info.st_mode):
                remove_tree_verified(directory_fd, child_name, child_info)
            else:
                unlink_verified(directory_fd, child_name, child_info)
        verify_identity(os.fstat(directory_fd), current, "cleanup directory {}".format(name))
    finally:
        os.close(directory_fd)

    current = lstat_at(parent_fd, name)
    if current is None:
        raise PublicationError("{} disappeared before rmdir".format(name))
    verify_identity(current, expected, "cleanup directory {}".format(name))
    os.rmdir(name, dir_fd=parent_fd)


def encoded_identity(info):
    return [info.st_dev, info.st_ino]


def identity_matches(info, expected):
    return info is not None and expected is not None and encoded_identity(info) == expected


def validate_encoded_identity(value, label):
    if value is None:
        return
    if (
        not isinstance(value, list)
        or len(value) != 2
        or any(not isinstance(part, int) or isinstance(part, bool) or part < 0 for part in value)
    ):
        raise PublicationError("transaction journal {} identity is invalid".format(label))


def read_small_json_at(parent_fd, name, label):
    before = lstat_at(parent_fd, name)
    if before is None:
        return None, None
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        raise PublicationError("{} must be a regular non-symlink file".format(label))
    if before.st_uid != os.geteuid():
        raise PublicationError("{} must be owned by uid {}".format(label, os.geteuid()))
    if before.st_size > TRANSACTION_JOURNAL_MAX_BYTES:
        raise PublicationError("{} exceeds the size limit".format(label))
    descriptor = os.open(name, os.O_RDONLY | O_NOFOLLOW, dir_fd=parent_fd)
    try:
        opened = os.fstat(descriptor)
        verify_identity(opened, before, label)
        chunks = []
        total = 0
        while True:
            chunk = os.read(descriptor, 8192)
            if not chunk:
                break
            total += len(chunk)
            if total > TRANSACTION_JOURNAL_MAX_BYTES:
                raise PublicationError("{} exceeds the size limit".format(label))
            chunks.append(chunk)
    finally:
        os.close(descriptor)
    try:
        payload = json.loads(b"".join(chunks).decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise PublicationError("{} is not valid UTF-8 JSON: {}".format(label, error))
    return payload, before


def validate_uncommitted_journal_temp(macos_fd):
    before = lstat_at(macos_fd, TRANSACTION_JOURNAL_TEMP_FILE)
    if before is None:
        return None
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        raise PublicationError("transaction journal temporary file must be a regular non-symlink file")
    if before.st_uid != os.geteuid():
        raise PublicationError(
            "transaction journal temporary file must be owned by uid {}".format(os.geteuid())
        )
    descriptor = os.open(
        TRANSACTION_JOURNAL_TEMP_FILE,
        os.O_RDONLY | O_NOFOLLOW,
        dir_fd=macos_fd,
    )
    try:
        verify_identity(
            os.fstat(descriptor),
            before,
            "transaction journal temporary file",
        )
    finally:
        os.close(descriptor)
    return before


def require_canonical_recorded_path(path, publication_parent, label):
    if not isinstance(path, str) or not os.path.isabs(path) or os.path.normpath(path) != path:
        raise PublicationError("transaction journal {} path is not canonical".format(label))
    try:
        within_parent = os.path.commonpath((publication_parent, path)) == publication_parent
    except ValueError:
        within_parent = False
    if not within_parent:
        raise PublicationError(
            "transaction journal {} path is outside the expected publication parent".format(label)
        )


def validate_transaction_journal(payload, macos_path, unsigned_path):
    if not isinstance(payload, dict):
        raise PublicationError("transaction journal root must be an object")
    if payload.get("schemaVersion") != TRANSACTION_JOURNAL_SCHEMA_VERSION:
        raise PublicationError("unsupported transaction journal schema")
    if payload.get("phase") not in TRANSACTION_PHASES:
        raise PublicationError("transaction journal phase is invalid")
    paths = payload.get("paths")
    if not isinstance(paths, dict):
        raise PublicationError("transaction journal paths must be an object")

    expected_fixed = {
        "publicationParent": macos_path,
        "unsignedParent": unsigned_path,
        "app": os.path.join(unsigned_path, "Seer.app"),
        "provenance": os.path.join(macos_path, PROVENANCE_FILE),
    }
    for key, expected in expected_fixed.items():
        actual = paths.get(key)
        require_canonical_recorded_path(actual, macos_path, key)
        if actual != expected:
            raise PublicationError(
                "transaction journal {} path does not match the fixed publication path".format(key)
            )

    dynamic_paths = {
        "stage": (unsigned_path, STAGE_NAME_PATTERN),
        "appBackup": (unsigned_path, APP_BACKUP_NAME_PATTERN),
        "provenanceTemp": (macos_path, PROVENANCE_TEMP_NAME_PATTERN),
        "provenanceBackup": (macos_path, PROVENANCE_BACKUP_NAME_PATTERN),
    }
    for key, (expected_parent, pattern) in dynamic_paths.items():
        path = paths.get(key)
        require_canonical_recorded_path(path, macos_path, key)
        if os.path.dirname(path) != expected_parent or pattern.fullmatch(os.path.basename(path)) is None:
            raise PublicationError("transaction journal {} path is not a valid private leaf".format(key))

    for key in ("oldApp", "oldProvenance"):
        record = payload.get(key)
        if not isinstance(record, dict) or record.get("present") not in (None, True, False):
            raise PublicationError("transaction journal {} record is invalid".format(key))
        present = record.get("present")
        if present is not None and type(present) is not bool:
            raise PublicationError("transaction journal {} presence flag is invalid".format(key))
        validate_encoded_identity(record.get("identity"), key)
        if present is True and record.get("identity") is None:
            raise PublicationError("transaction journal {} is missing its identity".format(key))
        if present is False and record.get("identity") is not None:
            raise PublicationError("transaction journal {} has an unexpected identity".format(key))
    validate_encoded_identity(payload.get("newAppIdentity"), "new app")
    validate_encoded_identity(payload.get("newProvenanceIdentity"), "new provenance")
    return payload


def validate_recovery_artifacts(payload, macos_fd, unsigned_fd):
    directory_entries = [
        (unsigned_fd, os.path.basename(payload["paths"]["stage"]), "private staging directory"),
        (unsigned_fd, os.path.basename(payload["paths"]["appBackup"]), "private app backup"),
    ]
    file_entries = [
        (macos_fd, os.path.basename(payload["paths"]["provenanceTemp"]), "private provenance temp"),
        (macos_fd, os.path.basename(payload["paths"]["provenanceBackup"]), "private provenance backup"),
    ]
    if payload["oldApp"]["present"] is not None:
        directory_entries.append((unsigned_fd, "Seer.app", "published app"))
    if payload["oldProvenance"]["present"] is not None:
        file_entries.append((macos_fd, PROVENANCE_FILE, "published provenance"))
    for parent_fd, name, label in directory_entries:
        info = lstat_at(parent_fd, name)
        if info is None:
            continue
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
            raise PublicationError("{} must be a real directory during recovery".format(label))
        if info.st_uid != os.geteuid():
            raise PublicationError("{} is not owned by uid {}".format(label, os.geteuid()))
    for parent_fd, name, label in file_entries:
        info = lstat_at(parent_fd, name)
        if info is None:
            continue
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
            raise PublicationError("{} must be a regular non-symlink file during recovery".format(label))
        if info.st_uid != os.geteuid():
            raise PublicationError("{} is not owned by uid {}".format(label, os.geteuid()))


def persist_transaction_journal(macos_fd, payload):
    encoded = (json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
    if len(encoded) > TRANSACTION_JOURNAL_MAX_BYTES:
        raise PublicationError("transaction journal exceeds the size limit")
    if lstat_at(macos_fd, TRANSACTION_JOURNAL_TEMP_FILE) is not None:
        raise PublicationError("transaction journal temporary file already exists")
    descriptor = os.open(
        TRANSACTION_JOURNAL_TEMP_FILE,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | O_NOFOLLOW,
        0o600,
        dir_fd=macos_fd,
    )
    try:
        offset = 0
        while offset < len(encoded):
            offset += os.write(descriptor, encoded[offset:])
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.rename(
        TRANSACTION_JOURNAL_TEMP_FILE,
        TRANSACTION_JOURNAL_FILE,
        src_dir_fd=macos_fd,
        dst_dir_fd=macos_fd,
    )
    os.fsync(macos_fd)


def load_transaction_journal(macos_fd, unsigned_fd, macos_path, unsigned_path):
    payload, journal_info = read_small_json_at(
        macos_fd,
        TRANSACTION_JOURNAL_FILE,
        "transaction journal",
    )
    if payload is not None:
        validate_transaction_journal(payload, macos_path, unsigned_path)
        validate_recovery_artifacts(payload, macos_fd, unsigned_fd)

    temp_info = validate_uncommitted_journal_temp(macos_fd)
    if temp_info is not None:
        unlink_verified(macos_fd, TRANSACTION_JOURNAL_TEMP_FILE, temp_info)
        os.fsync(macos_fd)
    return payload, journal_info


def remove_recovery_entry(parent_fd, name, expected_identity, label, directory):
    info = lstat_at(parent_fd, name)
    if info is None:
        return
    if expected_identity is not None and not identity_matches(info, expected_identity):
        raise PublicationError("{} changed identity during recovery".format(label))
    if directory:
        remove_tree_verified(parent_fd, name, info)
    else:
        unlink_verified(parent_fd, name, info)


def restore_old_entry(
    parent_fd,
    destination_name,
    backup_name,
    old_record,
    new_identity,
    label,
    directory,
):
    destination = lstat_at(parent_fd, destination_name)
    backup = lstat_at(parent_fd, backup_name)
    old_present = old_record["present"]
    old_identity = old_record["identity"]
    if old_present is None:
        if backup is not None:
            raise PublicationError("unexpected {} backup before transaction preparation".format(label))
        return
    if old_present:
        if identity_matches(destination, old_identity):
            if backup is not None:
                raise PublicationError("duplicate old {} found during recovery".format(label))
            return
        if not identity_matches(backup, old_identity):
            raise PublicationError("old {} backup is missing or changed during recovery".format(label))
        if destination is not None:
            if not identity_matches(destination, new_identity):
                raise PublicationError("new {} changed identity during recovery".format(label))
            if directory:
                remove_tree_verified(parent_fd, destination_name, destination)
            else:
                unlink_verified(parent_fd, destination_name, destination)
        os.rename(backup_name, destination_name, src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
        return
    if backup is not None:
        raise PublicationError("unexpected {} backup for an initially absent entry".format(label))
    if destination is not None:
        if not identity_matches(destination, new_identity):
            raise PublicationError("new {} changed identity during recovery".format(label))
        if directory:
            remove_tree_verified(parent_fd, destination_name, destination)
        else:
            unlink_verified(parent_fd, destination_name, destination)


def remove_transaction_journal(macos_fd, unsigned_fd):
    journal_info = lstat_at(macos_fd, TRANSACTION_JOURNAL_FILE)
    if journal_info is None:
        raise PublicationError("transaction journal disappeared before recovery completed")
    unlink_verified(macos_fd, TRANSACTION_JOURNAL_FILE, journal_info)
    os.fsync(unsigned_fd)
    os.fsync(macos_fd)


def rollback_transaction(payload, macos_fd, unsigned_fd):
    paths = payload["paths"]
    restore_old_entry(
        macos_fd,
        PROVENANCE_FILE,
        os.path.basename(paths["provenanceBackup"]),
        payload["oldProvenance"],
        payload.get("newProvenanceIdentity"),
        "provenance",
        False,
    )
    restore_old_entry(
        unsigned_fd,
        "Seer.app",
        os.path.basename(paths["appBackup"]),
        payload["oldApp"],
        payload.get("newAppIdentity"),
        "app",
        True,
    )
    remove_recovery_entry(
        macos_fd,
        os.path.basename(paths["provenanceTemp"]),
        payload.get("newProvenanceIdentity"),
        "private provenance temp",
        False,
    )
    remove_recovery_entry(
        unsigned_fd,
        os.path.basename(paths["stage"]),
        None,
        "private staging directory",
        True,
    )
    os.fsync(unsigned_fd)
    os.fsync(macos_fd)
    remove_transaction_journal(macos_fd, unsigned_fd)


def finish_committed_transaction(payload, macos_fd, unsigned_fd):
    paths = payload["paths"]
    app_info = lstat_at(unsigned_fd, "Seer.app")
    provenance_info = lstat_at(macos_fd, PROVENANCE_FILE)
    if not identity_matches(app_info, payload.get("newAppIdentity")):
        raise PublicationError("committed app is missing or changed during recovery")
    if not identity_matches(provenance_info, payload.get("newProvenanceIdentity")):
        raise PublicationError("committed provenance is missing or changed during recovery")

    if payload["phase"] != "cleanup":
        payload["phase"] = "cleanup"
        persist_transaction_journal(macos_fd, payload)
    remove_recovery_entry(
        unsigned_fd,
        os.path.basename(paths["appBackup"]),
        payload["oldApp"]["identity"],
        "private app backup",
        True,
    )
    remove_recovery_entry(
        macos_fd,
        os.path.basename(paths["provenanceBackup"]),
        payload["oldProvenance"]["identity"],
        "private provenance backup",
        False,
    )
    remove_recovery_entry(
        macos_fd,
        os.path.basename(paths["provenanceTemp"]),
        payload.get("newProvenanceIdentity"),
        "private provenance temp",
        False,
    )
    remove_recovery_entry(
        unsigned_fd,
        os.path.basename(paths["stage"]),
        None,
        "private staging directory",
        True,
    )
    remove_transaction_journal(macos_fd, unsigned_fd)


def recover_abandoned_transaction(
    macos_fd,
    unsigned_fd,
    macos_path,
    unsigned_path,
    force_rollback=False,
):
    payload, _ = load_transaction_journal(
        macos_fd,
        unsigned_fd,
        macos_path,
        unsigned_path,
    )
    if payload is None:
        return
    if force_rollback or payload["phase"] not in ("pair-published", "cleanup"):
        if payload["phase"] != "rolling-back":
            payload["phase"] = "rolling-back"
            persist_transaction_journal(macos_fd, payload)
        rollback_transaction(payload, macos_fd, unsigned_fd)
    else:
        finish_committed_transaction(payload, macos_fd, unsigned_fd)


def new_transaction_journal(macos_path, unsigned_path):
    token = secrets.token_hex(16)
    provenance_token = secrets.token_hex(16)
    provenance_backup_token = secrets.token_hex(16)
    return {
        "schemaVersion": TRANSACTION_JOURNAL_SCHEMA_VERSION,
        "phase": "staging",
        "paths": {
            "publicationParent": macos_path,
            "unsignedParent": unsigned_path,
            "app": os.path.join(unsigned_path, "Seer.app"),
            "provenance": os.path.join(macos_path, PROVENANCE_FILE),
            "stage": os.path.join(unsigned_path, ".seer-stage-{}".format(token)),
            "appBackup": os.path.join(unsigned_path, ".seer-backup-{}".format(secrets.token_hex(16))),
            "provenanceTemp": os.path.join(
                macos_path,
                ".seer-provenance-{}.json".format(provenance_token),
            ),
            "provenanceBackup": os.path.join(
                macos_path,
                ".seer-provenance-backup-{}.json".format(provenance_backup_token),
            ),
        },
        "oldApp": {"present": None, "identity": None},
        "oldProvenance": {"present": None, "identity": None},
        "newAppIdentity": None,
        "newProvenanceIdentity": None,
    }


def run_test_hook(
    hook_path,
    configured_phase,
    current_phase,
    unsigned_path,
    stage_name,
    interruptions,
):
    if not hook_path or configured_phase != current_phase:
        return
    environment = dict(os.environ)
    environment["SEER_PUBLISH_PARENT_PATH"] = unsigned_path
    environment["SEER_PUBLISH_STAGE_NAME"] = stage_name
    environment["SEER_PUBLISH_HOOK_PHASE"] = current_phase
    try:
        subprocess.run([hook_path], check=True, env=environment)
    except BaseException:
        interruptions.raise_if_pending()
        raise
    interruptions.raise_if_pending()


def publish(args):
    canonical_repo_root = os.path.realpath(os.path.normpath(args.repo_root))
    if canonical_repo_root != os.path.normpath(args.repo_root):
        raise PublicationError("repo root must be supplied as its canonical path")

    normalized_derived_data_path = os.path.normpath(args.derived_data_path)
    effective_derived_data_path = os.path.realpath(normalized_derived_data_path)
    if not os.path.isabs(effective_derived_data_path) or not os.path.isdir(effective_derived_data_path):
        raise PublicationError("derived-data path must resolve to an existing absolute directory")
    if effective_derived_data_path != normalized_derived_data_path:
        raise PublicationError("derived-data path must be supplied as its canonical path")

    repo_fd, repo_info = open_repo_root(canonical_repo_root)
    chain = []
    stage_fd = None
    publication_lock_fd = None
    interruptions = None
    transaction_started = False
    transaction_committed = False
    macos_path = os.path.join(canonical_repo_root, "build", "macos")
    unsigned_path = os.path.join(macos_path, "unsigned")
    try:
        chain = open_output_chain(repo_fd, create=True)
        macos_fd = chain[1][0]
        unsigned_fd = chain[2][0]
        publication_lock_fd = acquire_publication_lock(macos_fd)
        interruptions = SignalDeferral()
        interruptions.install()

        recover_abandoned_transaction(
            macos_fd,
            unsigned_fd,
            macos_path,
            unsigned_path,
        )
        interruptions.raise_if_pending()

        journal = new_transaction_journal(macos_path, unsigned_path)
        persist_transaction_journal(macos_fd, journal)
        transaction_started = True
        stage_name = os.path.basename(journal["paths"]["stage"])
        copy_hook_ran = False

        def run_copy_hook_once():
            nonlocal copy_hook_ran
            if copy_hook_ran:
                return
            copy_hook_ran = True
            run_test_hook(
                args.test_hook,
                args.test_hook_phase,
                "during-copy",
                unsigned_path,
                stage_name,
                interruptions,
            )

        stage_name, stage_fd, _, staged_app_info = stage_source_app(
            args.source_app,
            unsigned_fd,
            stage_name,
            run_copy_hook_once,
        )
        interruptions.raise_if_pending()
        run_test_hook(
            args.test_hook,
            args.test_hook_phase,
            "after-staging",
            unsigned_path,
            stage_name,
            interruptions,
        )
        interruptions.raise_if_pending()

        fresh_repo_fd, fresh_chain = reopen_and_verify_output_chain(
            canonical_repo_root,
            repo_info,
            chain,
        )
        try:
            fresh_macos_fd = fresh_chain[1][0]
            fresh_unsigned_fd = fresh_chain[2][0]

            app_digest = compute_staged_app_digest(stage_fd)
            try:
                validate_staged_architecture(stage_fd, unsigned_path, stage_name)
            except BaseException:
                interruptions.raise_if_pending()
                raise
            interruptions.raise_if_pending()
            provenance_temp_name = os.path.basename(journal["paths"]["provenanceTemp"])
            write_provenance_temp(
                fresh_macos_fd,
                provenance_temp_name,
                canonical_repo_root,
                effective_derived_data_path,
                app_digest,
            )
            provenance_temp_info = lstat_at(fresh_macos_fd, provenance_temp_name)
            if provenance_temp_info is None:
                raise PublicationError("private provenance temp disappeared")
            interruptions.raise_if_pending()

            destination_info = lstat_at(fresh_unsigned_fd, "Seer.app")
            if destination_info is not None:
                if stat.S_ISLNK(destination_info.st_mode) or not stat.S_ISDIR(destination_info.st_mode):
                    raise PublicationError(
                        "destination Seer.app is a symlink or non-directory; refusing to replace it"
                    )
            old_provenance_info = lstat_at(fresh_macos_fd, PROVENANCE_FILE)
            if old_provenance_info is not None:
                if stat.S_ISLNK(old_provenance_info.st_mode) or not stat.S_ISREG(
                    old_provenance_info.st_mode
                ):
                    raise PublicationError("existing provenance must be a regular non-symlink file")

            journal["oldApp"] = {
                "present": destination_info is not None,
                "identity": encoded_identity(destination_info) if destination_info is not None else None,
            }
            journal["oldProvenance"] = {
                "present": old_provenance_info is not None,
                "identity": (
                    encoded_identity(old_provenance_info)
                    if old_provenance_info is not None
                    else None
                ),
            }
            journal["newAppIdentity"] = encoded_identity(staged_app_info)
            journal["newProvenanceIdentity"] = encoded_identity(provenance_temp_info)
            journal["phase"] = "prepared"
            persist_transaction_journal(fresh_macos_fd, journal)

            app_backup_name = os.path.basename(journal["paths"]["appBackup"])
            if destination_info is not None:
                os.rename(
                    "Seer.app",
                    app_backup_name,
                    src_dir_fd=fresh_unsigned_fd,
                    dst_dir_fd=fresh_unsigned_fd,
                )
                app_backup_info = lstat_at(fresh_unsigned_fd, app_backup_name)
                if app_backup_info is None:
                    raise PublicationError("old Seer.app disappeared while moving it to backup")
                verify_identity(app_backup_info, destination_info, "private app backup")
                os.fsync(fresh_unsigned_fd)
            journal["phase"] = "app-backed-up"
            persist_transaction_journal(fresh_macos_fd, journal)

            provenance_backup_name = os.path.basename(journal["paths"]["provenanceBackup"])
            if old_provenance_info is not None:
                os.rename(
                    PROVENANCE_FILE,
                    provenance_backup_name,
                    src_dir_fd=fresh_macos_fd,
                    dst_dir_fd=fresh_macos_fd,
                )
                os.fsync(fresh_macos_fd)
            journal["phase"] = "provenance-backed-up"
            persist_transaction_journal(fresh_macos_fd, journal)

            os.rename(
                "Seer.app",
                "Seer.app",
                src_dir_fd=stage_fd,
                dst_dir_fd=fresh_unsigned_fd,
            )
            os.fsync(fresh_unsigned_fd)
            published_info = lstat_at(fresh_unsigned_fd, "Seer.app")
            if published_info is None:
                raise PublicationError("published Seer.app disappeared")
            verify_identity(published_info, staged_app_info, "published Seer.app")
            journal["phase"] = "app-published"
            persist_transaction_journal(fresh_macos_fd, journal)

            run_test_hook(
                args.test_hook,
                args.test_hook_phase,
                "after-app-publish",
                unsigned_path,
                stage_name,
                interruptions,
            )
            if args.test_failpoint == "after-app-publish":
                raise PublicationError("injected failure after app publication")
            interruptions.raise_if_pending()

            os.rename(
                provenance_temp_name,
                PROVENANCE_FILE,
                src_dir_fd=fresh_macos_fd,
                dst_dir_fd=fresh_macos_fd,
            )
            os.fsync(fresh_macos_fd)
            os.fsync(fresh_unsigned_fd)
            interruptions.raise_if_pending()
            journal["phase"] = "pair-published"
            persist_transaction_journal(fresh_macos_fd, journal)
            transaction_committed = True
            os.close(stage_fd)
            stage_fd = None
            recover_abandoned_transaction(
                fresh_macos_fd,
                fresh_unsigned_fd,
                macos_path,
                unsigned_path,
            )
            transaction_started = False
            interruptions.raise_if_pending()
        finally:
            for descriptor, _ in reversed(fresh_chain):
                os.close(descriptor)
            os.close(fresh_repo_fd)
    except BaseException as original_error:
        if stage_fd is not None:
            os.close(stage_fd)
            stage_fd = None
        if transaction_started and len(chain) >= 3:
            try:
                recover_abandoned_transaction(
                    chain[1][0],
                    chain[2][0],
                    macos_path,
                    unsigned_path,
                    force_rollback=not transaction_committed,
                )
                transaction_started = False
            except BaseException as cleanup_error:
                raise PublicationError(
                    "publication failed ({}) and transaction recovery was uncertain ({}); "
                    "journal and private artifacts retained".format(original_error, cleanup_error)
                ) from original_error
        if interruptions is not None:
            interruptions.raise_if_pending()
        raise
    finally:
        if publication_lock_fd is not None:
            fcntl.flock(publication_lock_fd, fcntl.LOCK_UN)
            os.close(publication_lock_fd)
        if interruptions is not None:
            interruptions.restore()
        if stage_fd is not None:
            os.close(stage_fd)
        for descriptor, _ in reversed(chain):
            os.close(descriptor)
        os.close(repo_fd)


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", required=True)
    parser.add_argument("--source-app", required=True)
    parser.add_argument("--derived-data-path", required=True)
    parser.add_argument("--test-hook", help=argparse.SUPPRESS)
    parser.add_argument(
        "--test-hook-phase",
        choices=["during-copy", "after-staging", "after-app-publish"],
        default="after-staging",
        help=argparse.SUPPRESS,
    )
    parser.add_argument("--test-failpoint", choices=["after-app-publish"], help=argparse.SUPPRESS)
    return parser.parse_args()


def main():
    try:
        publish(parse_args())
    except DeferredSignal as interruption:
        print("error: {}".format(interruption), file=sys.stderr)
        return 128 + interruption.signal_number
    except KeyboardInterrupt:
        print("error: interrupted by SIGINT", file=sys.stderr)
        return 128 + signal.SIGINT
    except (OSError, PublicationError, subprocess.SubprocessError) as error:
        print("error: {}".format(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
