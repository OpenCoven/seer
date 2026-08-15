#!/usr/bin/env python3
"""Copy and atomically publish Seer.app without following output-path symlinks."""

import argparse
import json
import os
import secrets
import stat
import subprocess
import sys


O_NOFOLLOW = getattr(os, "O_NOFOLLOW", None)
if O_NOFOLLOW is None:
    raise RuntimeError("publish-macos-app.py requires O_NOFOLLOW")

DIRECTORY_OPEN_FLAGS = os.O_RDONLY | os.O_DIRECTORY | O_NOFOLLOW
PROVENANCE_FILE = "standalone-build-provenance.json"


class PublicationError(RuntimeError):
    pass


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


def copy_regular_file(source_fd, destination_fd, name, source_info):
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


def copy_tree_contents(source_fd, destination_fd):
    for name in os.listdir(source_fd):
        source_info = lstat_at(source_fd, name)
        if source_info is None:
            raise PublicationError("source entry {!r} disappeared during copy".format(name))
        if stat.S_ISLNK(source_info.st_mode):
            raise PublicationError("source entry {!r} is a symlink; bundle copies never follow symlinks".format(name))
        if stat.S_ISREG(source_info.st_mode):
            copy_regular_file(source_fd, destination_fd, name, source_info)
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
                copy_tree_contents(source_child, destination_child)
                os.fchmod(destination_child, stat.S_IMODE(source_info.st_mode))
                os.fsync(destination_child)
            finally:
                os.close(destination_child)
                os.close(source_child)
            continue
        raise PublicationError("source entry {!r} is neither a regular file nor a directory".format(name))


def stage_source_app(source_app, unsigned_fd):
    source_before = os.lstat(source_app)
    if stat.S_ISLNK(source_before.st_mode) or not stat.S_ISDIR(source_before.st_mode):
        raise PublicationError("source app must be a real directory, not a symlink")
    source_fd = os.open(source_app, DIRECTORY_OPEN_FLAGS)
    source_after = os.fstat(source_fd)
    try:
        verify_identity(source_after, source_before, "source app")
        stage_name = ".seer-stage-{}".format(secrets.token_hex(16))
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
                copy_tree_contents(source_fd, staged_app_fd)
                os.fchmod(staged_app_fd, stat.S_IMODE(source_before.st_mode))
                os.fsync(staged_app_fd)
            finally:
                os.close(staged_app_fd)
            os.fsync(stage_fd)
            return stage_name, stage_fd, stage_info, staged_app_info
        except Exception:
            os.close(stage_fd)
            raise
    finally:
        os.close(source_fd)


def write_provenance_temp(macos_fd, canonical_repo_root, effective_derived_data_path):
    payload = {
        "schemaVersion": 1,
        "canonicalRepoRoot": canonical_repo_root,
        "effectiveDerivedDataPath": effective_derived_data_path,
    }
    encoded = (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode("utf-8")
    temp_name = ".seer-provenance-{}.json".format(secrets.token_hex(16))
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


def run_test_hook(hook_path, unsigned_path, stage_name):
    if not hook_path:
        return
    environment = dict(os.environ)
    environment["SEER_PUBLISH_PARENT_PATH"] = unsigned_path
    environment["SEER_PUBLISH_STAGE_NAME"] = stage_name
    subprocess.run([hook_path], check=True, env=environment)


def publish(args):
    canonical_repo_root = os.path.realpath(os.path.normpath(args.repo_root))
    if canonical_repo_root != os.path.normpath(args.repo_root):
        raise PublicationError("repo root must be supplied as its canonical path")

    effective_derived_data_path = os.path.realpath(os.path.normpath(args.derived_data_path))
    if not os.path.isabs(effective_derived_data_path) or not os.path.isdir(effective_derived_data_path):
        raise PublicationError("derived-data path must resolve to an existing absolute directory")

    repo_fd, repo_info = open_repo_root(canonical_repo_root)
    chain = []
    stage_name = None
    stage_fd = None
    provenance_temp = None
    try:
        chain = open_output_chain(repo_fd, create=True)
        build_fd = chain[0][0]
        macos_fd = chain[1][0]
        unsigned_fd = chain[2][0]
        del build_fd

        stage_name, stage_fd, stage_info, staged_app_info = stage_source_app(args.source_app, unsigned_fd)
        provenance_temp = write_provenance_temp(
            macos_fd,
            canonical_repo_root,
            effective_derived_data_path,
        )

        unsigned_path = os.path.join(canonical_repo_root, "build", "macos", "unsigned")
        run_test_hook(args.test_hook, unsigned_path, stage_name)

        fresh_repo_fd, fresh_chain = reopen_and_verify_output_chain(
            canonical_repo_root,
            repo_info,
            chain,
        )
        backup_name = None
        backup_info = None
        new_app_published = False
        try:
            fresh_macos_fd = fresh_chain[1][0]
            fresh_unsigned_fd = fresh_chain[2][0]

            destination_info = lstat_at(fresh_unsigned_fd, "Seer.app")
            if destination_info is not None:
                if stat.S_ISLNK(destination_info.st_mode):
                    raise PublicationError("destination Seer.app is a symlink; refusing to replace it")
                backup_name = ".seer-backup-{}".format(secrets.token_hex(16))
                os.rename(
                    "Seer.app",
                    backup_name,
                    src_dir_fd=fresh_unsigned_fd,
                    dst_dir_fd=fresh_unsigned_fd,
                )
                backup_info = lstat_at(fresh_unsigned_fd, backup_name)
                if backup_info is None:
                    raise PublicationError("old Seer.app disappeared while moving it to backup")
                verify_identity(backup_info, destination_info, "private backup")

            try:
                os.rename(
                    "Seer.app",
                    "Seer.app",
                    src_dir_fd=stage_fd,
                    dst_dir_fd=fresh_unsigned_fd,
                )
                new_app_published = True
                published_info = lstat_at(fresh_unsigned_fd, "Seer.app")
                if published_info is None:
                    raise PublicationError("published Seer.app disappeared")
                verify_identity(published_info, staged_app_info, "published Seer.app")

                os.rename(
                    provenance_temp,
                    PROVENANCE_FILE,
                    src_dir_fd=fresh_macos_fd,
                    dst_dir_fd=fresh_macos_fd,
                )
                provenance_temp = None
                os.fsync(fresh_macos_fd)
                os.fsync(fresh_unsigned_fd)
            except Exception as error:
                rollback_errors = []
                try:
                    if new_app_published:
                        os.rename(
                            "Seer.app",
                            "Seer.app",
                            src_dir_fd=fresh_unsigned_fd,
                            dst_dir_fd=stage_fd,
                        )
                    if backup_name is not None:
                        os.rename(
                            backup_name,
                            "Seer.app",
                            src_dir_fd=fresh_unsigned_fd,
                            dst_dir_fd=fresh_unsigned_fd,
                        )
                except Exception as rollback_error:
                    rollback_errors.append(str(rollback_error))
                if rollback_errors:
                    raise PublicationError(
                        "publication failed ({}) and rollback was uncertain ({}); staging retained".format(
                            error,
                            "; ".join(rollback_errors),
                        )
                    )
                raise

            if backup_name is not None:
                remove_tree_verified(fresh_unsigned_fd, backup_name, backup_info)

            os.close(stage_fd)
            stage_fd = None
            current_stage = lstat_at(fresh_unsigned_fd, stage_name)
            if current_stage is None:
                raise PublicationError("private staging directory disappeared before cleanup")
            verify_identity(current_stage, stage_info, "private staging directory")
            os.rmdir(stage_name, dir_fd=fresh_unsigned_fd)
            stage_name = None
        finally:
            for descriptor, _ in reversed(fresh_chain):
                os.close(descriptor)
            os.close(fresh_repo_fd)
    except Exception:
        if provenance_temp is not None and len(chain) >= 2:
            try:
                temp_info = lstat_at(chain[1][0], provenance_temp)
                if temp_info is not None:
                    unlink_verified(chain[1][0], provenance_temp, temp_info)
            except Exception:
                pass
        if stage_name is not None:
            print(
                "error: publication failed closed; retained private staging leaf {!r} for scoped cleanup".format(
                    stage_name
                ),
                file=sys.stderr,
            )
        raise
    finally:
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
    return parser.parse_args()


def main():
    try:
        publish(parse_args())
    except (OSError, PublicationError, subprocess.SubprocessError) as error:
        print("error: {}".format(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
