#!/usr/bin/env python3
"""Create and validate the inert unsigned-app artifact passed between release runners."""

import argparse
import hashlib
import io
import json
import os
from pathlib import PurePosixPath
import re
import stat
import tarfile


SCHEMA_VERSION = 2
APP_DIGEST_ALGORITHM = "sha256-files-v1"
ARCHIVE_FORMAT = "ustar"
BOUNDARY_VERSION = "task14-release-v1"
BOUNDARY_VALIDATION = "passed"
PREPARE_BINDING_ALGORITHM = "sha256-lines-v1"
EXPECTED_ARCHIVE_NAME = "Seer-unsigned-arm64.tar"
EXPECTED_ATTESTATION_NAME = "unsigned-app-attestation.json"
MAX_ARCHIVE_SIZE = 1024 * 1024 * 1024
MAX_MEMBER_SIZE = 512 * 1024 * 1024
MAX_MEMBER_COUNT = 20000
MAX_ATTESTATION_SIZE = 64 * 1024


class ReleaseInputError(Exception):
    pass


def sha256_bytes(value):
    return hashlib.sha256(value).hexdigest()


def validate_entry_name(name):
    if not name or any(character in name for character in ("/", "\\", "\0", "\n", "\r", ":")):
        raise ReleaseInputError("unsafe app entry name {!r}".format(name))
    if name in (".", ".."):
        raise ReleaseInputError("unsafe app entry name {!r}".format(name))


def absolute_path_parts(path, description):
    if not os.path.isabs(path):
        raise ReleaseInputError("{} path must be absolute".format(description))
    parts = path.split(os.sep)
    if parts[0] != "" or any(part in ("", ".", "..") for part in parts[1:]):
        raise ReleaseInputError("{} path is not canonical".format(description))
    return parts[1:]


def open_directory_path_nofollow(path, description):
    parts = absolute_path_parts(path, description)
    descriptor = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in parts:
            next_descriptor = os.open(
                part,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=descriptor,
            )
            os.close(descriptor)
            descriptor = next_descriptor
        return descriptor
    except Exception:
        os.close(descriptor)
        raise


def open_parent_path_nofollow(path, description):
    parts = absolute_path_parts(path, description)
    if not parts:
        raise ReleaseInputError("{} cannot be the filesystem root".format(description))
    parent_path = "/" + "/".join(parts[:-1]) if len(parts) > 1 else "/"
    return open_directory_path_nofollow(parent_path, description), parts[-1]


def collect_app(app_path):
    entries = []

    def walk(directory_fd, prefix):
        names = sorted(os.listdir(directory_fd), key=lambda value: value.encode("utf-8"))
        for name in names:
            validate_entry_name(name)
            relative_path = "{}/{}".format(prefix, name) if prefix else name
            before = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
            if stat.S_ISLNK(before.st_mode):
                raise ReleaseInputError("app archive cannot contain symlink {!r}".format(relative_path))
            if stat.S_ISDIR(before.st_mode):
                child_fd = os.open(
                    name,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                    dir_fd=directory_fd,
                )
                try:
                    after = os.fstat(child_fd)
                    if (
                        not stat.S_ISDIR(after.st_mode)
                        or before.st_dev != after.st_dev
                        or before.st_ino != after.st_ino
                    ):
                        raise ReleaseInputError(
                            "app archive directory changed identity while opening: {!r}".format(
                                relative_path
                            )
                        )
                    entries.append(("directory", relative_path, None, after, None))
                    walk(child_fd, relative_path)
                finally:
                    os.close(child_fd)
                continue
            if not stat.S_ISREG(before.st_mode):
                raise ReleaseInputError(
                    "app archive entry must be a regular file or directory: {!r}".format(relative_path)
                )

            descriptor = os.open(
                name,
                os.O_RDONLY | os.O_NOFOLLOW,
                dir_fd=directory_fd,
            )
            try:
                after = os.fstat(descriptor)
                if (
                    not stat.S_ISREG(after.st_mode)
                    or before.st_dev != after.st_dev
                    or before.st_ino != after.st_ino
                ):
                    raise ReleaseInputError(
                        "app archive entry changed identity while opening: {!r}".format(relative_path)
                    )
                chunks = []
                while True:
                    chunk = os.read(descriptor, 1024 * 1024)
                    if not chunk:
                        break
                    chunks.append(chunk)
                contents = b"".join(chunks)
            finally:
                os.close(descriptor)
            entries.append(("file", relative_path, None, after, contents))

    root_fd = open_directory_path_nofollow(app_path, "app bundle")
    try:
        root_after = os.fstat(root_fd)
        if not stat.S_ISDIR(root_after.st_mode):
            raise ReleaseInputError("app bundle must be a real directory")
        walk(root_fd, "")
        return root_after, entries
    finally:
        os.close(root_fd)


def compute_app_digest(entries):
    lines = []
    for entry_type, relative_path, _absolute_path, _info, contents in entries:
        if entry_type == "file":
            lines.append("{}:{}\n".format(relative_path, sha256_bytes(contents)))
    return sha256_bytes("".join(lines).encode("utf-8"))


def normalized_mode(entry_type, source_mode):
    if entry_type == "directory":
        return 0o755
    return 0o755 if source_mode & 0o111 else 0o644


def tar_info(name, entry_type, source_mode, size=0):
    info = tarfile.TarInfo(name)
    info.type = tarfile.DIRTYPE if entry_type == "directory" else tarfile.REGTYPE
    info.mode = normalized_mode(entry_type, source_mode)
    info.uid = 0
    info.gid = 0
    info.uname = ""
    info.gname = ""
    info.mtime = 0
    info.size = size
    return info


def require_new_regular_output(path):
    parent_fd, name = open_parent_path_nofollow(path, "release input output")
    try:
        try:
            os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        except FileNotFoundError:
            return
        raise ReleaseInputError("refusing to replace release input output: {}".format(path))
    finally:
        os.close(parent_fd)


def open_new_output(path):
    parent_fd, name = open_parent_path_nofollow(path, "release input output")
    try:
        return os.open(
            name,
            os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
            dir_fd=parent_fd,
        )
    finally:
        os.close(parent_fd)


def create_release_input(args):
    if os.path.basename(args.app) != "Seer.app":
        raise ReleaseInputError("app input must use the fixed Seer.app name")
    if (
        os.path.basename(args.archive) != EXPECTED_ARCHIVE_NAME
        or os.path.basename(args.attestation) != EXPECTED_ATTESTATION_NAME
    ):
        raise ReleaseInputError("release input must use fixed artifact names")
    if not re.fullmatch(r"[0-9a-f]{40}", args.source_commit):
        raise ReleaseInputError("source commit must be a lowercase 40-character SHA")
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", args.version):
        raise ReleaseInputError("version must be stable X.Y.Z semantic version")
    if not re.fullmatch(r"[1-9][0-9]*", args.build_number):
        raise ReleaseInputError("build number must be a positive integer")
    if args.bundle_identifier != "ai.opencoven.seer" or args.architecture != "arm64":
        raise ReleaseInputError("release identity must be ai.opencoven.seer arm64")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}", args.prepare_runner_id):
        raise ReleaseInputError("prepare runner ID is malformed")
    require_new_regular_output(args.archive)
    require_new_regular_output(args.attestation)
    root_info, entries = collect_app(args.app)
    app_digest = compute_app_digest(entries)
    archive_entry_names = ["Seer.app/"]
    for entry_type, relative_path, _absolute_path, _info, _contents in entries:
        suffix = "/" if entry_type == "directory" else ""
        archive_entry_names.append("Seer.app/{}{}".format(relative_path, suffix))
    archive_entry_list = "".join("{}\n".format(name) for name in archive_entry_names)
    archive_entry_list_sha256 = sha256_bytes(archive_entry_list.encode("utf-8"))

    archive_descriptor = open_new_output(args.archive)
    with os.fdopen(archive_descriptor, "w+b") as archive_file:
        os.fchmod(archive_descriptor, 0o644)
        with tarfile.open(fileobj=archive_file, mode="w", format=tarfile.USTAR_FORMAT) as archive:
            archive.addfile(tar_info("Seer.app", "directory", root_info.st_mode))
            for entry_type, relative_path, _absolute_path, info, contents in entries:
                archive_name = "Seer.app/{}".format(relative_path)
                if entry_type == "directory":
                    archive.addfile(tar_info(archive_name, entry_type, info.st_mode))
                else:
                    archive.addfile(
                        tar_info(archive_name, entry_type, info.st_mode, len(contents)),
                        io.BytesIO(contents),
                    )

        archive_file.flush()
        archive_info = os.fstat(archive_descriptor)
        archive_file.seek(0)
        archive_sha256 = hashlib.sha256(archive_file.read()).hexdigest()
    prepare_binding = "".join(
        (
            "prepareRunnerId:{}\n".format(args.prepare_runner_id),
            "sourceCommit:{}\n".format(args.source_commit),
            "archiveSha256:{}\n".format(archive_sha256),
            "appDigest:{}\n".format(app_digest),
            "entryListSha256:{}\n".format(archive_entry_list_sha256),
        )
    )
    metadata = {
        "schemaVersion": SCHEMA_VERSION,
        "sourceCommit": args.source_commit,
        "version": args.version,
        "buildNumber": args.build_number,
        "bundleIdentifier": args.bundle_identifier,
        "architecture": args.architecture,
        "appDigestAlgorithm": APP_DIGEST_ALGORITHM,
        "appDigest": app_digest,
        "archiveFormat": ARCHIVE_FORMAT,
        "archive": {
            "entryCount": len(archive_entry_names),
            "entryListSha256": archive_entry_list_sha256,
            "name": os.path.basename(args.archive),
            "sha256": archive_sha256,
            "size": archive_info.st_size,
        },
        "boundary": BOUNDARY_VERSION,
        "boundaryValidation": BOUNDARY_VALIDATION,
        "prepareRunnerId": args.prepare_runner_id,
        "prepareBindingAlgorithm": PREPARE_BINDING_ALGORITHM,
        "prepareBindingSha256": sha256_bytes(prepare_binding.encode("utf-8")),
    }
    attestation_descriptor = open_new_output(args.attestation)
    with os.fdopen(attestation_descriptor, "w", encoding="utf-8", newline="\n") as attestation_file:
        json.dump(metadata, attestation_file, indent=2, sort_keys=True)
        attestation_file.write("\n")
        attestation_file.flush()
        os.fchmod(attestation_descriptor, 0o644)


def read_regular_file(path, maximum_size, description):
    parent_fd, name = open_parent_path_nofollow(path, description)
    try:
        before = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
            raise ReleaseInputError("{} must be a regular non-symlink file".format(description))
        if before.st_size > maximum_size:
            raise ReleaseInputError("{} exceeds the size limit".format(description))
        descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent_fd)
        try:
            after = os.fstat(descriptor)
            if (
                not stat.S_ISREG(after.st_mode)
                or before.st_dev != after.st_dev
                or before.st_ino != after.st_ino
            ):
                raise ReleaseInputError("{} changed identity while opening".format(description))
            chunks = []
            total = 0
            while True:
                chunk = os.read(descriptor, 1024 * 1024)
                if not chunk:
                    break
                total += len(chunk)
                if total > maximum_size:
                    raise ReleaseInputError("{} exceeds the size limit".format(description))
                chunks.append(chunk)
            return b"".join(chunks), after
        finally:
            os.close(descriptor)
    finally:
        os.close(parent_fd)


def validate_attestation(metadata, args, archive_size):
    expected_keys = {
        "appDigest",
        "appDigestAlgorithm",
        "architecture",
        "archive",
        "archiveFormat",
        "boundary",
        "boundaryValidation",
        "buildNumber",
        "bundleIdentifier",
        "prepareBindingAlgorithm",
        "prepareBindingSha256",
        "prepareRunnerId",
        "schemaVersion",
        "sourceCommit",
        "version",
    }
    if not isinstance(metadata, dict) or set(metadata) != expected_keys:
        raise ReleaseInputError("unsigned-app attestation has missing or unexpected fields")
    archive = metadata["archive"]
    if not isinstance(archive, dict) or set(archive) != {
        "entryCount",
        "entryListSha256",
        "name",
        "sha256",
        "size",
    }:
        raise ReleaseInputError("unsigned-app archive attestation has missing or unexpected fields")
    string_fields = (
        "sourceCommit",
        "version",
        "buildNumber",
        "bundleIdentifier",
        "architecture",
        "appDigestAlgorithm",
        "appDigest",
        "archiveFormat",
        "boundary",
        "boundaryValidation",
        "prepareBindingAlgorithm",
        "prepareBindingSha256",
        "prepareRunnerId",
    )
    if type(metadata["schemaVersion"]) is not int or any(
        not isinstance(metadata[field], str) for field in string_fields
    ):
        raise ReleaseInputError("unsigned-app attestation field types are invalid")
    if (
        not isinstance(archive["name"], str)
        or not isinstance(archive["sha256"], str)
        or not isinstance(archive["entryListSha256"], str)
        or type(archive["entryCount"]) is not int
        or type(archive["size"]) is not int
    ):
        raise ReleaseInputError("unsigned-app archive attestation field types are invalid")
    expected_values = {
        "schemaVersion": SCHEMA_VERSION,
        "sourceCommit": args.expected_source_commit,
        "version": args.expected_version,
        "buildNumber": args.expected_build_number,
        "bundleIdentifier": "ai.opencoven.seer",
        "architecture": "arm64",
        "appDigestAlgorithm": APP_DIGEST_ALGORITHM,
        "archiveFormat": ARCHIVE_FORMAT,
        "boundary": BOUNDARY_VERSION,
        "boundaryValidation": BOUNDARY_VALIDATION,
        "prepareBindingAlgorithm": PREPARE_BINDING_ALGORITHM,
        "prepareRunnerId": args.expected_prepare_runner_id,
    }
    for field, expected in expected_values.items():
        if metadata[field] != expected:
            raise ReleaseInputError(
                "unsigned-app attestation {} mismatch: expected {!r}".format(field, expected)
            )
    if not re.fullmatch(r"[0-9a-f]{64}", metadata["appDigest"]):
        raise ReleaseInputError("unsigned-app attestation appDigest is malformed")
    if not re.fullmatch(r"[0-9a-f]{64}", metadata["prepareBindingSha256"]):
        raise ReleaseInputError("unsigned-app attestation prepare binding is malformed")
    if not re.fullmatch(r"[0-9a-f]{64}", archive["entryListSha256"]):
        raise ReleaseInputError("unsigned-app attestation entry-list digest is malformed")
    if archive["entryCount"] < 1 or archive["entryCount"] > MAX_MEMBER_COUNT:
        raise ReleaseInputError("unsigned-app attestation entry count is invalid")
    if archive["name"] != EXPECTED_ARCHIVE_NAME:
        raise ReleaseInputError("unsigned-app attestation archive name is not fixed")
    if archive["sha256"] != args.expected_archive_sha256:
        raise ReleaseInputError("unsigned-app attestation archive SHA-256 mismatch")
    if archive["size"] != archive_size:
        raise ReleaseInputError("unsigned-app attestation archive size mismatch")
    prepare_binding = "".join(
        (
            "prepareRunnerId:{}\n".format(metadata["prepareRunnerId"]),
            "sourceCommit:{}\n".format(metadata["sourceCommit"]),
            "archiveSha256:{}\n".format(archive["sha256"]),
            "appDigest:{}\n".format(metadata["appDigest"]),
            "entryListSha256:{}\n".format(archive["entryListSha256"]),
        )
    )
    if sha256_bytes(prepare_binding.encode("utf-8")) != metadata["prepareBindingSha256"]:
        raise ReleaseInputError("unsigned-app attestation prepare binding mismatch")


def validate_archive_name(name):
    if not name or "\\" in name or name.startswith("/"):
        raise ReleaseInputError("unsafe archive entry {!r}".format(name))
    parts = PurePosixPath(name).parts
    if any(part in ("", ".", "..") for part in parts):
        raise ReleaseInputError("unsafe archive entry {!r}".format(name))
    if name != "/".join(parts):
        raise ReleaseInputError("unsafe archive entry {!r}".format(name))
    if parts[0] != "Seer.app":
        raise ReleaseInputError("unexpected archive root entry {!r}".format(name))
    for part in parts:
        validate_entry_name(part)
    return parts


def validate_archive_members(archive, archive_size):
    members = archive.getmembers()
    if not members or len(members) > MAX_MEMBER_COUNT:
        raise ReleaseInputError("unsigned-app archive has an invalid entry count")
    if members[0].name != "Seer.app" or not members[0].isdir():
        raise ReleaseInputError("unsigned-app archive must begin with the real Seer.app root")

    seen = set()
    directories = set()
    total_size = 0
    for member in members:
        parts = validate_archive_name(member.name)
        if member.name in seen:
            raise ReleaseInputError("duplicate archive entry {!r}".format(member.name))
        seen.add(member.name)
        if member.issym() or member.islnk():
            raise ReleaseInputError("archive links are forbidden: {!r}".format(member.name))
        if not member.isdir() and not member.isreg():
            raise ReleaseInputError(
                "archive entry must be a regular file or directory: {!r}".format(member.name)
            )
        if member.pax_headers or member.issparse():
            raise ReleaseInputError("extended or sparse archive entries are forbidden")
        expected_mode = 0o755 if member.isdir() or member.mode & 0o111 else 0o644
        if (
            member.uid != 0
            or member.gid != 0
            or member.uname not in ("", None)
            or member.gname not in ("", None)
            or member.mtime != 0
            or member.mode != expected_mode
        ):
            raise ReleaseInputError("archive entry metadata is not canonical: {!r}".format(member.name))
        if len(parts) > 1 and "/".join(parts[:-1]) not in directories:
            raise ReleaseInputError(
                "archive parent directory was not declared first: {!r}".format(member.name)
            )
        if member.isdir():
            directories.add(member.name)
        else:
            if member.size < 0 or member.size > MAX_MEMBER_SIZE:
                raise ReleaseInputError("archive member exceeds the size limit: {!r}".format(member.name))
            total_size += member.size
            if total_size > MAX_ARCHIVE_SIZE:
                raise ReleaseInputError("archive expanded contents exceed the size limit")

    logical_end = archive.offset
    archive.fileobj.seek(logical_end)
    trailing = archive.fileobj.read()
    if (
        archive_size % tarfile.BLOCKSIZE != 0
        or len(trailing) < tarfile.BLOCKSIZE * 2
        or any(trailing)
    ):
        raise ReleaseInputError("archive has non-canonical or appended trailing bytes")
    return members


def open_directory_at(parent_fd, name):
    return os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)


def open_parent_directory(root_fd, parts):
    descriptor = os.dup(root_fd)
    try:
        for part in parts:
            next_descriptor = open_directory_at(descriptor, part)
            os.close(descriptor)
            descriptor = next_descriptor
        return descriptor
    except Exception:
        os.close(descriptor)
        raise


def extract_members(archive, members, destination):
    root_fd = open_directory_path_nofollow(destination, "extraction destination")
    try:
        destination_info = os.fstat(root_fd)
        if not stat.S_ISDIR(destination_info.st_mode):
            raise ReleaseInputError("extraction destination must be a real directory")
        if os.listdir(root_fd):
            raise ReleaseInputError("extraction destination must be empty")
        for member in members:
            parts = member.name.split("/")
            parent_fd = open_parent_directory(root_fd, parts[:-1])
            try:
                leaf = parts[-1]
                if member.isdir():
                    os.mkdir(leaf, 0o755, dir_fd=parent_fd)
                    continue
                source = archive.extractfile(member)
                if source is None:
                    raise ReleaseInputError("unable to read archive member {!r}".format(member.name))
                descriptor = os.open(
                    leaf,
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                    member.mode,
                    dir_fd=parent_fd,
                )
                try:
                    remaining = member.size
                    while remaining:
                        chunk = source.read(min(1024 * 1024, remaining))
                        if not chunk:
                            raise ReleaseInputError(
                                "archive member ended early: {!r}".format(member.name)
                            )
                        pending = memoryview(chunk)
                        while pending:
                            written = os.write(descriptor, pending)
                            if written <= 0:
                                raise ReleaseInputError(
                                    "unable to write archive member: {!r}".format(member.name)
                                )
                            pending = pending[written:]
                        remaining -= len(chunk)
                    if source.read(1):
                        raise ReleaseInputError(
                            "archive member exceeded declared size: {!r}".format(member.name)
                        )
                    os.fchmod(descriptor, member.mode)
                finally:
                    os.close(descriptor)
                    source.close()
            finally:
                os.close(parent_fd)
    finally:
        os.close(root_fd)


def validate_release_input(args):
    if not re.fullmatch(r"[0-9a-f]{64}", args.expected_archive_sha256):
        raise ReleaseInputError("expected archive SHA-256 is malformed")
    if not re.fullmatch(r"[0-9a-f]{40}", args.expected_source_commit):
        raise ReleaseInputError("expected source commit is malformed")
    if not re.fullmatch(
        r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)",
        args.expected_version,
    ):
        raise ReleaseInputError("expected version is malformed")
    if not re.fullmatch(r"[1-9][0-9]*", args.expected_build_number):
        raise ReleaseInputError("expected build number is malformed")
    if not re.fullmatch(
        r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}", args.expected_prepare_runner_id
    ):
        raise ReleaseInputError("expected prepare runner ID is malformed")
    if (
        os.path.basename(args.archive) != EXPECTED_ARCHIVE_NAME
        or os.path.basename(args.attestation) != EXPECTED_ATTESTATION_NAME
    ):
        raise ReleaseInputError("release input must use fixed artifact names")
    archive_bytes, archive_info = read_regular_file(
        args.archive, MAX_ARCHIVE_SIZE, "unsigned-app archive"
    )
    actual_archive_sha256 = sha256_bytes(archive_bytes)
    if actual_archive_sha256 != args.expected_archive_sha256:
        raise ReleaseInputError("unsigned-app archive SHA-256 mismatch")

    attestation_bytes, _attestation_info = read_regular_file(
        args.attestation, MAX_ATTESTATION_SIZE, "unsigned-app attestation"
    )
    try:
        metadata = json.loads(attestation_bytes.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ReleaseInputError("invalid unsigned-app attestation JSON: {}".format(error))
    validate_attestation(metadata, args, archive_info.st_size)

    archive_stream = io.BytesIO(archive_bytes)
    with tarfile.open(fileobj=archive_stream, mode="r:", format=tarfile.USTAR_FORMAT) as archive:
        members = validate_archive_members(archive, archive_info.st_size)
        entry_list = "".join(
            "{}{}\n".format(member.name, "/" if member.isdir() else "") for member in members
        )
        if len(members) != metadata["archive"]["entryCount"]:
            raise ReleaseInputError("archive entry count does not match unsigned-app attestation")
        if sha256_bytes(entry_list.encode("utf-8")) != metadata["archive"]["entryListSha256"]:
            raise ReleaseInputError("archive entry list does not match unsigned-app attestation")
        extract_members(archive, members, args.destination)

    _root_info, extracted_entries = collect_app(os.path.join(args.destination, "Seer.app"))
    actual_app_digest = compute_app_digest(extracted_entries)
    if actual_app_digest != metadata["appDigest"]:
        raise ReleaseInputError("extracted app digest does not match unsigned-app attestation")


def parser():
    argument_parser = argparse.ArgumentParser()
    subparsers = argument_parser.add_subparsers(dest="command", required=True)
    create = subparsers.add_parser("create")
    create.add_argument("--app", required=True)
    create.add_argument("--archive", required=True)
    create.add_argument("--attestation", required=True)
    create.add_argument("--source-commit", required=True)
    create.add_argument("--version", required=True)
    create.add_argument("--build-number", required=True)
    create.add_argument("--bundle-identifier", required=True)
    create.add_argument("--architecture", required=True)
    create.add_argument("--prepare-runner-id", required=True)
    validate = subparsers.add_parser("validate")
    validate.add_argument("--archive", required=True)
    validate.add_argument("--attestation", required=True)
    validate.add_argument("--expected-archive-sha256", required=True)
    validate.add_argument("--expected-source-commit", required=True)
    validate.add_argument("--expected-version", required=True)
    validate.add_argument("--expected-build-number", required=True)
    validate.add_argument("--expected-prepare-runner-id", required=True)
    validate.add_argument("--destination", required=True)
    return argument_parser


def main():
    args = parser().parse_args()
    try:
        if args.command == "create":
            create_release_input(args)
        elif args.command == "validate":
            validate_release_input(args)
    except (OSError, ReleaseInputError, tarfile.TarError) as error:
        raise SystemExit("error: {}".format(error))


if __name__ == "__main__":
    main()
