#!/usr/bin/env swift
import CryptoKit
import Darwin
import Foundation

private struct RendererDigestFailure: Error {
    let message: String
}

private struct ObservedIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    let isDirectory: Bool
    let isRegularFile: Bool
    let isSymbolicLink: Bool

    init(_ value: stat) {
        device = UInt64(value.st_dev)
        inode = UInt64(value.st_ino)
        size = Int64(value.st_size)
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
        isDirectory = (value.st_mode & S_IFMT) == S_IFDIR
        isRegularFile = (value.st_mode & S_IFMT) == S_IFREG
        isSymbolicLink = (value.st_mode & S_IFMT) == S_IFLNK
    }

    func isSameObject(as other: ObservedIdentity) -> Bool {
        device == other.device && inode == other.inode
    }
}

private struct DirectoryRecord {
    let descriptor: Int32
    let parentIndex: Int?
    let name: String
    let relativePath: String
    let identity: ObservedIdentity
    let belongsToRenderer: Bool
}

private struct AssetRecord {
    let descriptor: Int32
    let parentDirectoryIndex: Int
    let name: String
    let relativePath: String
    let identity: ObservedIdentity
}

private struct AssetHash: Encodable {
    let relativePath: String
    let sha256: String
}

private struct CollectionHook: Decodable {
    let executable: String
    let args: [String]
}

private final class DescriptorPool {
    private var descriptors: [Int32] = []

    func retain(_ descriptor: Int32) {
        descriptors.append(descriptor)
    }

    func closeAll() {
        for descriptor in descriptors.reversed() {
            _ = Darwin.close(descriptor)
        }
        descriptors.removeAll()
    }
}

private func failure(_ message: String) -> RendererDigestFailure {
    RendererDigestFailure(message: message)
}

/// Compares root-relative POSIX paths by their exact UTF-8 byte sequences.
/// This intentionally does not use locale collation, case folding, or Unicode
/// normalization; it must match `compareRendererAssetPaths` in
/// `renderer-build-identity.mjs`.
private func canonicalPathPrecedes(_ left: String, _ right: String) -> Bool {
    let leftBytes = Array(left.utf8)
    let rightBytes = Array(right.utf8)
    let commonCount = min(leftBytes.count, rightBytes.count)
    for index in 0 ..< commonCount where leftBytes[index] != rightBytes[index] {
        return leftBytes[index] < rightBytes[index]
    }
    return leftBytes.count < rightBytes.count
}

private func systemError(_ context: String, _ code: Int32 = errno) -> RendererDigestFailure {
    failure("\(context): \(String(cString: strerror(code)))")
}

private func inspect(_ descriptor: Int32, _ context: String) throws -> ObservedIdentity {
    var value = stat()
    guard Darwin.fstat(descriptor, &value) == 0 else {
        throw systemError("unable to inspect \(context)")
    }
    return ObservedIdentity(value)
}

private func inspectNamedEntry(
    parent: Int32,
    name: String,
    context: String
) throws -> ObservedIdentity {
    var value = stat()
    let result = name.withCString {
        Darwin.fstatat(parent, $0, &value, AT_SYMLINK_NOFOLLOW)
    }
    guard result == 0 else {
        throw systemError("unable to inspect \(context) without following symlinks")
    }
    return ObservedIdentity(value)
}

private func withClosedDescriptor<T>(_ descriptor: Int32, _ body: (Int32) throws -> T) throws -> T {
    defer {
        _ = Darwin.close(descriptor)
    }
    return try body(descriptor)
}

private func openRootDirectory(parent: Int32, name: String, absolutePath: String) throws -> (Int32, ObservedIdentity) {
    let namedIdentity = try inspectNamedEntry(
        parent: parent,
        name: name,
        context: "renderer root directory \(absolutePath)"
    )
    if namedIdentity.isSymbolicLink {
        throw failure("renderer root must not contain a symlink: \(absolutePath)")
    }
    guard namedIdentity.isDirectory else {
        throw failure("renderer root must be a directory: \(absolutePath)")
    }
    let descriptor = name.withCString {
        Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    }
    guard descriptor >= 0 else {
        if errno == ELOOP {
            throw failure("renderer root must not contain a symlink: \(absolutePath)")
        }
        throw systemError("unable to open renderer root directory without following symlinks: \(absolutePath)")
    }
    do {
        let identity = try inspect(descriptor, "renderer root directory \(absolutePath)")
        guard identity.isDirectory && identity.isSameObject(as: namedIdentity) else {
            throw failure("renderer root changed identity while being opened: \(absolutePath)")
        }
        return (descriptor, identity)
    } catch {
        _ = Darwin.close(descriptor)
        throw error
    }
}

private func tryOpenAssetDirectory(parent: Int32, name: String, relativePath: String) throws -> (Int32, ObservedIdentity)? {
    let namedIdentity = try inspectNamedEntry(
        parent: parent,
        name: name,
        context: "renderer asset \(relativePath)"
    )
    if (namedIdentity.isSymbolicLink || !namedIdentity.isDirectory) {
        return nil
    }
    let descriptor = name.withCString {
        Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    }
    guard descriptor >= 0 else {
        if errno == ELOOP {
            throw failure("renderer asset directory must not be a symlink: \(relativePath)")
        }
        throw systemError("unable to open renderer asset directory without following symlinks: \(relativePath)")
    }
    do {
        let identity = try inspect(descriptor, "renderer asset directory \(relativePath)")
        guard identity.isDirectory && identity.isSameObject(as: namedIdentity) else {
            throw failure("renderer asset directory changed identity while being opened: \(relativePath)")
        }
        return (descriptor, identity)
    } catch {
        _ = Darwin.close(descriptor)
        throw error
    }
}

private func openAssetFile(parent: Int32, name: String, relativePath: String) throws -> (Int32, ObservedIdentity) {
    let namedIdentity = try inspectNamedEntry(
        parent: parent,
        name: name,
        context: "renderer asset \(relativePath)"
    )
    if namedIdentity.isSymbolicLink {
        throw failure("renderer asset must not be a symlink: \(relativePath)")
    }
    let descriptor = name.withCString {
        Darwin.openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    }
    guard descriptor >= 0 else {
        if errno == ELOOP {
            throw failure("renderer asset must not be a symlink: \(relativePath)")
        }
        throw systemError("unable to open renderer asset without following symlinks: \(relativePath)")
    }
    do {
        let identity = try inspect(descriptor, "renderer asset \(relativePath)")
        guard identity.isRegularFile else {
            throw failure("renderer asset must be a regular file after opening: \(relativePath)")
        }
        guard identity.isSameObject(as: namedIdentity) else {
            throw failure("renderer asset changed identity while being opened: \(relativePath)")
        }
        return (descriptor, identity)
    } catch {
        _ = Darwin.close(descriptor)
        throw error
    }
}

private func directoryEntryNames(_ directory: DirectoryRecord) throws -> [String] {
    let identity = try inspect(directory.descriptor, "renderer asset directory \(directory.relativePath)")
    guard identity.isDirectory && identity.isSameObject(as: directory.identity) else {
        throw failure("renderer asset directory changed identity while being collected: \(directory.relativePath)")
    }

    let duplicate = Darwin.dup(directory.descriptor)
    guard duplicate >= 0 else {
        throw systemError("unable to duplicate renderer asset directory descriptor: \(directory.relativePath)")
    }
    guard let stream = Darwin.fdopendir(duplicate) else {
        _ = Darwin.close(duplicate)
        throw systemError("unable to enumerate renderer asset directory: \(directory.relativePath)")
    }
    defer {
        _ = Darwin.closedir(stream)
    }

    var names: [String] = []
    while true {
        errno = 0
        guard let entry = Darwin.readdir(stream) else {
            if errno != 0 {
                throw systemError("unable to enumerate renderer asset directory: \(directory.relativePath)")
            }
            break
        }
        let name = withUnsafePointer(to: entry.pointee.d_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN)) {
                String(cString: $0)
            }
        }
        if name != "." && name != ".." {
            names.append(name)
        }
    }
    return names.sorted(by: canonicalPathPrecedes)
}

private func collectAssets(
    from directoryIndex: Int,
    relativePrefix: String,
    directories: inout [DirectoryRecord],
    assets: inout [AssetRecord],
    pool: DescriptorPool
) throws {
    let parent = directories[directoryIndex]
    for name in try directoryEntryNames(parent) {
        let relativePath = relativePrefix.isEmpty ? name : "\(relativePrefix)/\(name)"
        if relativePath == "build-manifest.json" {
            continue
        }

        if let (descriptor, identity) = try tryOpenAssetDirectory(
            parent: parent.descriptor,
            name: name,
            relativePath: relativePath
        ) {
            pool.retain(descriptor)
            let childIndex = directories.count
            directories.append(
                DirectoryRecord(
                    descriptor: descriptor,
                    parentIndex: directoryIndex,
                    name: name,
                    relativePath: relativePath,
                    identity: identity,
                    belongsToRenderer: true
                )
            )
            try collectAssets(
                from: childIndex,
                relativePrefix: relativePath,
                directories: &directories,
                assets: &assets,
                pool: pool
            )
            continue
        }

        let (descriptor, identity) = try openAssetFile(
            parent: parent.descriptor,
            name: name,
            relativePath: relativePath
        )
        pool.retain(descriptor)
        assets.append(
            AssetRecord(
                descriptor: descriptor,
                parentDirectoryIndex: directoryIndex,
                name: name,
                relativePath: relativePath,
                identity: identity
            )
        )
    }
}

private func verifyRootBindings(_ directories: [DirectoryRecord], rootIndex: Int) throws {
    guard rootIndex > 0 else {
        return
    }
    for index in 1 ... rootIndex {
        let directory = directories[index]
        guard let parentIndex = directory.parentIndex else {
            throw failure("renderer root descriptor hierarchy is incomplete")
        }
        let parent = directories[parentIndex]
        let absolutePath = directory.relativePath
        let (descriptor, identity) = try openRootDirectory(
            parent: parent.descriptor,
            name: directory.name,
            absolutePath: absolutePath
        )
        try withClosedDescriptor(descriptor) { _ in
            guard identity.isDirectory && identity.isSameObject(as: directory.identity) else {
                throw failure("renderer root changed identity while hashing: \(absolutePath)")
            }
        }
    }
}

private func verifyAssetDirectoryBinding(
    _ directory: DirectoryRecord,
    parent: DirectoryRecord
) throws {
    let namedIdentity = try inspectNamedEntry(
        parent: parent.descriptor,
        name: directory.name,
        context: "renderer asset directory \(directory.relativePath)"
    )
    if namedIdentity.isSymbolicLink {
        throw failure("renderer asset directory must not be a symlink: \(directory.relativePath)")
    }
    let (descriptor, identity) = try tryOpenAssetDirectory(
        parent: parent.descriptor,
        name: directory.name,
        relativePath: directory.relativePath
    ) ?? {
        throw failure("renderer asset directory changed identity while being opened: \(directory.relativePath)")
    }()
    try withClosedDescriptor(descriptor) { _ in
        guard identity.isDirectory && identity.isSameObject(as: directory.identity) else {
            throw failure("renderer asset directory changed identity while being opened: \(directory.relativePath)")
        }
    }
}

private func verifyAssetFileBinding(
    _ asset: AssetRecord,
    parent: DirectoryRecord
) throws {
    let (descriptor, identity) = try openAssetFile(
        parent: parent.descriptor,
        name: asset.name,
        relativePath: asset.relativePath
    )
    try withClosedDescriptor(descriptor) { _ in
        guard identity.isRegularFile && identity == asset.identity else {
            throw failure("renderer asset changed identity while being opened: \(asset.relativePath)")
        }
    }
}

private func verifyPinnedDescriptors(
    _ directories: [DirectoryRecord],
    rootIndex: Int,
    assets: [AssetRecord]
) throws {
    try verifyRootBindings(directories, rootIndex: rootIndex)

    for directory in directories where directory.belongsToRenderer && directory.parentIndex != nil && directory.relativePath != "/" {
        let parent = directories[directory.parentIndex!]
        try verifyAssetDirectoryBinding(directory, parent: parent)
    }
    for asset in assets {
        try verifyAssetFileBinding(asset, parent: directories[asset.parentDirectoryIndex])
    }

    for directory in directories where directory.belongsToRenderer {
        let current = try inspect(directory.descriptor, "renderer asset directory \(directory.relativePath)")
        guard current.isDirectory && current == directory.identity else {
            throw failure("renderer asset directory changed identity while hashing: \(directory.relativePath)")
        }
    }
    for asset in assets {
        let current = try inspect(asset.descriptor, "renderer asset \(asset.relativePath)")
        guard current.isRegularFile && current == asset.identity else {
            throw failure("renderer asset changed identity while being opened: \(asset.relativePath)")
        }
    }
}

private func sha256Hex(of descriptor: Int32, relativePath: String, expected: ObservedIdentity) throws -> String {
    guard Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else {
        throw systemError("unable to seek renderer asset: \(relativePath)")
    }

    var hasher = SHA256()
    var bytes = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = bytes.withUnsafeMutableBytes { buffer in
            Darwin.read(descriptor, buffer.baseAddress, buffer.count)
        }
        if count == 0 {
            break
        }
        if count < 0 {
            if errno == EINTR {
                continue
            }
            throw systemError("unable to read renderer asset: \(relativePath)")
        }
        hasher.update(data: Data(bytes[0 ..< Int(count)]))
    }

    let afterRead = try inspect(descriptor, "renderer asset \(relativePath)")
    guard afterRead.isRegularFile && afterRead == expected else {
        throw failure("renderer asset changed while hashing: \(relativePath)")
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

private func runHook(_ hook: CollectionHook?) throws {
    guard let hook else {
        return
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: hook.executable)
    process.arguments = hook.args
    try process.run()
    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        throw failure("renderer asset collection hook failed")
    }
}

private func parseArguments() throws -> (String, CollectionHook?) {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard !arguments.isEmpty else {
        throw failure("usage: renderer-asset-digest.swift <absolute-renderer-root> [--after-collection-hook <base64-json>]")
    }
    let root = arguments[0]
    guard root.hasPrefix("/") else {
        throw failure("renderer root must be an absolute path")
    }
    guard arguments.count == 1 || (arguments.count == 3 && arguments[1] == "--after-collection-hook") else {
        throw failure("usage: renderer-asset-digest.swift <absolute-renderer-root> [--after-collection-hook <base64-json>]")
    }
    guard arguments.count == 3 else {
        return (root, nil)
    }
    guard
        let encoded = Data(base64Encoded: arguments[2]),
        let hook = try? JSONDecoder().decode(CollectionHook.self, from: encoded),
        !hook.executable.isEmpty
    else {
        throw failure("renderer asset collection hook is invalid")
    }
    return (root, hook)
}

private func computeAssetHashes(rootPath: String, hook: CollectionHook?) throws -> [AssetHash] {
    let components = rootPath.split(separator: "/").map(String.init)
    guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
        throw failure("renderer root path is invalid")
    }

    let rootDescriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard rootDescriptor >= 0 else {
        throw systemError("unable to open filesystem root without following symlinks")
    }

    let pool = DescriptorPool()
    pool.retain(rootDescriptor)
    defer {
        pool.closeAll()
    }

    let rootIdentity = try inspect(rootDescriptor, "filesystem root")
    guard rootIdentity.isDirectory else {
        throw failure("filesystem root is not a directory")
    }
    var directories = [
        DirectoryRecord(
            descriptor: rootDescriptor,
            parentIndex: nil,
            name: "",
            relativePath: "/",
            identity: rootIdentity,
            belongsToRenderer: false
        )
    ]

    var pathSoFar = ""
    for component in components {
        pathSoFar += "/\(component)"
        let parentIndex = directories.count - 1
        let (descriptor, identity) = try openRootDirectory(
            parent: directories[parentIndex].descriptor,
            name: component,
            absolutePath: pathSoFar
        )
        pool.retain(descriptor)
        directories.append(
            DirectoryRecord(
                descriptor: descriptor,
                parentIndex: parentIndex,
                name: component,
                relativePath: pathSoFar,
                identity: identity,
                belongsToRenderer: false
            )
        )
    }
    let rendererRootIndex = directories.count - 1
    directories[rendererRootIndex] = DirectoryRecord(
        descriptor: directories[rendererRootIndex].descriptor,
        parentIndex: directories[rendererRootIndex].parentIndex,
        name: directories[rendererRootIndex].name,
        relativePath: directories[rendererRootIndex].relativePath,
        identity: directories[rendererRootIndex].identity,
        belongsToRenderer: true
    )

    var assets: [AssetRecord] = []
    try collectAssets(
        from: rendererRootIndex,
        relativePrefix: "",
        directories: &directories,
        assets: &assets,
        pool: pool
    )

    try runHook(hook)
    try verifyPinnedDescriptors(directories, rootIndex: rendererRootIndex, assets: assets)

    var hashes: [AssetHash] = []
    for asset in assets {
        hashes.append(
            AssetHash(
                relativePath: asset.relativePath,
                sha256: try sha256Hex(
                    of: asset.descriptor,
                    relativePath: asset.relativePath,
                    expected: asset.identity
                )
            )
        )
    }
    try verifyPinnedDescriptors(directories, rootIndex: rendererRootIndex, assets: assets)
    return hashes.sorted { canonicalPathPrecedes($0.relativePath, $1.relativePath) }
}

do {
    let (rootPath, hook) = try parseArguments()
    let hashes = try computeAssetHashes(rootPath: rootPath, hook: hook)
    let encoded = try JSONEncoder().encode(hashes)
    FileHandle.standardOutput.write(encoded)
    FileHandle.standardOutput.write(Data([0x0A]))
} catch let error as RendererDigestFailure {
    FileHandle.standardError.write(Data("\(error.message)\n".utf8))
    exit(1)
} catch {
    FileHandle.standardError.write(Data("renderer asset digest helper failed: \(error)\n".utf8))
    exit(1)
}
