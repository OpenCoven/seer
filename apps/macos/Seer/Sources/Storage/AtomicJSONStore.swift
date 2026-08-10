import Foundation

/// A JSON document whose on-disk schema is explicitly versioned.
///
/// `AtomicJSONStore` uses `currentVersion`/`defaultValue` to decide whether a
/// document on disk is decodable, from a future schema, or corrupt, without
/// depending on any single concrete document type.
public protocol VersionedDocument: Codable, Equatable, Sendable {
    /// The schema version this build of Seer knows how to read and write.
    static var currentVersion: Int { get }

    /// The value used whenever no valid on-disk document is available.
    static var defaultValue: Self { get }

    /// The schema version this particular instance was decoded as (or will
    /// be encoded as, for values constructed in memory).
    var version: Int { get }
}

/// Typed failures surfaced by `AtomicJSONStore`. Every failure path returns
/// or throws one of these cases rather than silently substituting a success
/// result — callers can distinguish "no file yet" from "something is
/// wrong" and react (e.g. surface a diagnostic) accordingly.
public enum StorageError: Error, Equatable, Sendable {
    /// The on-disk document declared a schema version newer than this build
    /// understands. The associated value is the version found on disk.
    case unsupportedVersion(Int)
    /// `save` was called after `load` determined the store is read-only.
    case writesDisabled
    /// The in-memory document could not be encoded to JSON.
    case encodeFailed
    /// The on-disk bytes could not be decoded into the expected document.
    case decodeFailed
    /// The on-disk file could not be read (permissions, I/O error, etc).
    case readFailed
    /// The temporary file could not be written/synchronized or the atomic
    /// replace into the destination failed.
    case writeFailed
    /// A corrupt file could not be moved aside into quarantine.
    case quarantineFailed
}

/// The result of `AtomicJSONStore.load()`. Load never throws: a missing,
/// corrupt, unreadable, or unsupported-version file all resolve to a usable
/// in-memory value (defaults) plus enough information for the caller to
/// decide whether persistence is currently safe and whether to surface a
/// diagnostic to the user.
public struct LoadResult<Document: Sendable>: Sendable {
    public let value: Document
    public let diagnostic: Diagnostic?
    /// Whether `save` may be called safely. `false` means the on-disk file
    /// is being deliberately left untouched (unsupported version or read
    /// failure) and any subsequent `save` call will throw
    /// `StorageError.writesDisabled`.
    public let writesEnabled: Bool

    public init(value: Document, diagnostic: Diagnostic?, writesEnabled: Bool) {
        self.value = value
        self.diagnostic = diagnostic
        self.writesEnabled = writesEnabled
    }
}

/// Errors thrown by a `SettingsFileSystem` implementation to let
/// `AtomicJSONStore` distinguish specific, meaningful failure modes from
/// generic I/O errors.
public enum SettingsFileSystemError: Error, Equatable, Sendable {
    /// `readFile(at:)` found no file at the given URL.
    case fileNotFound
    /// `moveItem(at:to:)` found an existing file already occupying the
    /// destination path (used by quarantine's collision-avoidance loop).
    case destinationAlreadyExists
    /// Any other I/O failure. `message` is diagnostic-only, not compared.
    case other(String)

    public static func == (lhs: SettingsFileSystemError, rhs: SettingsFileSystemError) -> Bool {
        switch (lhs, rhs) {
        case (.fileNotFound, .fileNotFound), (.destinationAlreadyExists, .destinationAlreadyExists):
            return true
        case let (.other(a), .other(b)):
            return a == b
        default:
            return false
        }
    }
}

/// The file-system boundary `AtomicJSONStore` depends on, injected so tests
/// can exercise every branch (missing file, corrupt bytes, read/write/move
/// failures, quarantine collisions) without touching real disk state or
/// relying on platform-specific permission quirks (`chmod`, etc). Production
/// code uses `FileManagerSettingsFileSystem`.
///
/// All operations are `async` so a purely in-memory `actor`-based test
/// double can safely be shared across concurrent calls, matching how the
/// real store (also an `actor`) serializes access.
public protocol SettingsFileSystem: Sendable {
    /// Creates `url` (and any missing intermediate directories) if it does
    /// not already exist. Must not fail if the directory already exists.
    func ensureDirectoryExists(at url: URL) async throws

    /// Reads the full contents of the file at `url`.
    /// - Throws: `SettingsFileSystemError.fileNotFound` if no file exists at
    ///   `url`; some other error for any other read failure.
    func readFile(at url: URL) async throws -> Data

    /// Writes `data` to a new file at `url` and ensures the bytes are
    /// flushed/synchronized to durable storage before returning. `url` is
    /// always a freshly chosen, unique sibling path — implementations do
    /// not need to handle overwriting an existing file here.
    func writeFileAndSynchronize(_ data: Data, to url: URL) async throws

    /// Atomically replaces `destination` with the contents at `source`. If
    /// `destination` does not yet exist, moves `source` into place instead.
    /// Either way, `source` no longer exists afterwards on success, and
    /// `destination`'s prior contents are preserved on failure.
    func replaceItem(at destination: URL, withItemAt source: URL) async throws

    /// Moves `source` to `destination`.
    /// - Throws: `SettingsFileSystemError.destinationAlreadyExists` if
    ///   `destination` already exists (`source` is left untouched in that
    ///   case); some other error for any other failure (`source` is left
    ///   untouched in that case too).
    func moveItem(at source: URL, to destination: URL) async throws

    /// Removes the file at `url`, used only to clean up an orphaned
    /// temporary file after a failed save.
    func removeItem(at url: URL) async throws
}

/// Production `SettingsFileSystem` backed by `FileManager`/`FileHandle`.
public struct FileManagerSettingsFileSystem: SettingsFileSystem {
    // `FileManager` is not `Sendable` in the SDK's annotations, but Apple's
    // documentation guarantees a single `FileManager` instance is safe to
    // use concurrently from multiple threads for the stateless, delegate-free
    // operations used here (no shared mutable state is exposed to callers).
    // `nonisolated(unsafe)` is scoped to this one field rather than
    // `@unchecked Sendable` on the whole type.
    private nonisolated(unsafe) let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func ensureDirectoryExists(at url: URL) async throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func fileExists(at url: URL) async -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    public func readFile(at url: URL) async throws -> Data {
        guard fileManager.fileExists(atPath: url.path) else {
            throw SettingsFileSystemError.fileNotFound
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw SettingsFileSystemError.other(String(describing: error))
        }
    }

    public func writeFileAndSynchronize(_ data: Data, to url: URL) async throws {
        guard fileManager.createFile(atPath: url.path, contents: nil) else {
            throw SettingsFileSystemError.other("createFile failed at \(url.path)")
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            throw SettingsFileSystemError.other(String(describing: error))
        }
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw SettingsFileSystemError.other(String(describing: error))
        }
    }

    public func replaceItem(at destination: URL, withItemAt source: URL) async throws {
        do {
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: source)
            } else {
                try fileManager.moveItem(at: source, to: destination)
            }
        } catch {
            throw SettingsFileSystemError.other(String(describing: error))
        }
    }

    public func moveItem(at source: URL, to destination: URL) async throws {
        if fileManager.fileExists(atPath: destination.path) {
            throw SettingsFileSystemError.destinationAlreadyExists
        }
        do {
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            throw SettingsFileSystemError.other(String(describing: error))
        }
    }

    public func removeItem(at url: URL) async throws {
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw SettingsFileSystemError.other(String(describing: error))
        }
    }
}

/// Diagnostic ids emitted by `AtomicJSONStore`. Kept as named constants so
/// production code and tests reference the exact same strings.
public enum StorageDiagnosticID {
    public static let unsupportedVersion = "storage.settings.unsupported-version"
    public static let readFailed = "storage.settings.read-failed"
    public static let corrupt = "storage.settings.corrupt"
    public static let quarantineFailed = "storage.settings.quarantine-failed"
}

/// Loads and saves a single versioned JSON document at a fixed file URL,
/// serializing all access as an `actor` so concurrent `load`/`save` calls
/// (e.g. rapid-fire settings mutations) apply in invocation order with no
/// interleaved partial writes.
///
/// Failure handling never silently discards data:
/// - A future/unsupported schema version leaves the file byte-for-byte
///   untouched and disables further writes for this instance.
/// - A read failure (permissions, I/O) leaves the file untouched and
///   disables further writes.
/// - A corrupt file (malformed JSON or invalid current-version data) is
///   moved aside into a timestamped `.corrupt-<millis>` sibling so it is
///   never silently discarded, and writes remain enabled since the store
///   safely owns a fresh default document going forward.
/// - If quarantining itself fails, the corrupt source is left in place and
///   writes are disabled.
/// A minimal, linear, non-backtracking JSON lexer plus decimal-string
/// classifier used to answer "what is the top-level `version` field, and
/// is it something this build supports, something newer, or invalid?"
/// without ever materializing the version value as `Double` or `Int`
/// (both of which can trap or misreport on the arbitrarily large numbers a
/// hand-edited or foreign-tool-written settings file might contain, e.g.
/// `1e309` or a 500-digit integer literal). Kept free of any generic
/// parameter (unlike `AtomicJSONStore<Document>` itself) so its
/// `static let`/`static func` members are ordinary ones, not subject to
/// Swift's "static stored properties not supported in generic types"
/// restriction.
fileprivate enum VersionProbing {
    /// The result of probing the top-level `version` field.
    enum Result {
        case supported
        /// A version this build cannot decode, described as text for
        /// diagnostics. Kept as `String` (not `Int`) because a well-formed
        /// integral JSON number (e.g. `1e100`, or a 500-digit literal) can
        /// vastly exceed `Int`'s range; a future version is always
        /// reported this way regardless of whether it happens to fit in
        /// an `Int`.
        case future(String)
        case invalid
    }

    /// Replaces the version number token with the single representable
    /// byte `0` and feeds the sanitized bytes to `JSONSerialization`,
    /// so a version token this build can't materialize as `Double`/`Int`
    /// never prevents validating the well-formedness of everything else
    /// in the document.
    static func isStructurallyValid(bytes: [UInt8], versionTokenRange range: Range<Int>) -> Bool {
        var sanitized = [UInt8]()
        sanitized.reserveCapacity(bytes.count - (range.upperBound - range.lowerBound) + 1)
        sanitized.append(contentsOf: bytes[bytes.startIndex..<range.lowerBound])
        sanitized.append(UInt8(ascii: "0"))
        sanitized.append(contentsOf: bytes[range.upperBound...])
        let sanitizedData = Data(sanitized)
        return (try? JSONSerialization.jsonObject(with: sanitizedData, options: [.fragmentsAllowed])) != nil
    }

    // MARK: - Lexical top-level `version` scan
    //
    // A minimal, linear, non-backtracking JSON lexer: it does exactly one
    // pass over the already-in-memory bytes (bounded by the file size
    // already read), tracking string/escape state and object/array
    // nesting just precisely enough to find the *top-level* `version`
    // member's number token by byte offset — without ever decoding the
    // number itself or the rest of the document.

    enum VersionKeyScan {
        /// The top-level `version` key was found and its value is a JSON
        /// number token spanning `range` (byte offsets into the scanned
        /// bytes).
        case numberToken(range: Range<Int>)
        /// The top-level `version` key was found, but its value is not a
        /// JSON number (string/object/array/`true`/`false`/`null`) — never
        /// a valid version.
        case nonNumericValue
        /// The root isn't a JSON object, the object has no top-level
        /// `version` key, or the bytes are malformed in a way that
        /// prevents determining an answer (e.g. an unterminated string or
        /// mismatched brackets encountered before reaching an answer).
        case notFound
    }

    static func scanTopLevelVersionToken(in bytes: [UInt8]) -> VersionKeyScan {
        var i = skipWhitespace(bytes, from: 0)
        guard i < bytes.count, bytes[i] == UInt8(ascii: "{") else {
            return .notFound
        }
        i += 1

        while true {
            i = skipWhitespace(bytes, from: i)
            guard i < bytes.count else { return .notFound }
            if bytes[i] == UInt8(ascii: "}") {
                return .notFound
            }
            guard bytes[i] == UInt8(ascii: "\""), let (keyBytes, afterKey) = scanStringLiteral(bytes, from: i) else {
                return .notFound
            }
            i = skipWhitespace(bytes, from: afterKey)
            guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { return .notFound }
            i = skipWhitespace(bytes, from: i + 1)
            guard i < bytes.count else { return .notFound }

            let isVersionKey = keyBytes.elementsEqual(Array("version".utf8))
            let b = bytes[i]
            let looksNumeric = b == UInt8(ascii: "-") || (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9"))

            if isVersionKey, looksNumeric {
                guard let end = scanNumberToken(bytes, from: i) else { return .notFound }
                return .numberToken(range: i..<end)
            }
            guard let afterValue = skipJSONValue(bytes, from: i) else { return .notFound }
            i = afterValue
            if isVersionKey {
                return .nonNumericValue
            }

            i = skipWhitespace(bytes, from: i)
            guard i < bytes.count else { return .notFound }
            if bytes[i] == UInt8(ascii: ",") {
                i += 1
                continue
            }
            if bytes[i] == UInt8(ascii: "}") {
                return .notFound
            }
            return .notFound
        }
    }

    static func skipWhitespace(_ bytes: [UInt8], from start: Int) -> Int {
        var i = start
        while i < bytes.count {
            switch bytes[i] {
            case 0x20, 0x09, 0x0A, 0x0D:
                i += 1
            default:
                return i
            }
        }
        return i
    }

    /// Recursively skips exactly one JSON value (string, number, object,
    /// array, or `true`/`false`/`null`) starting at `start`, returning the
    /// index just past it, or `nil` if the bytes are not a well-formed
    /// value there. Recursion depth is bounded by the JSON's own nesting
    /// depth, i.e. by the bytes already read from disk.
    static func skipJSONValue(_ bytes: [UInt8], from start: Int) -> Int? {
        guard start < bytes.count else { return nil }
        switch bytes[start] {
        case UInt8(ascii: "\""):
            guard let (_, end) = scanStringLiteral(bytes, from: start) else { return nil }
            return end

        case UInt8(ascii: "{"):
            var i = skipWhitespace(bytes, from: start + 1)
            guard i < bytes.count else { return nil }
            if bytes[i] == UInt8(ascii: "}") { return i + 1 }
            while true {
                guard bytes[i] == UInt8(ascii: "\""), let (_, afterKey) = scanStringLiteral(bytes, from: i) else {
                    return nil
                }
                i = skipWhitespace(bytes, from: afterKey)
                guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { return nil }
                i = skipWhitespace(bytes, from: i + 1)
                guard let afterValue = skipJSONValue(bytes, from: i) else { return nil }
                i = skipWhitespace(bytes, from: afterValue)
                guard i < bytes.count else { return nil }
                if bytes[i] == UInt8(ascii: ",") {
                    i = skipWhitespace(bytes, from: i + 1)
                    continue
                }
                if bytes[i] == UInt8(ascii: "}") { return i + 1 }
                return nil
            }

        case UInt8(ascii: "["):
            var i = skipWhitespace(bytes, from: start + 1)
            guard i < bytes.count else { return nil }
            if bytes[i] == UInt8(ascii: "]") { return i + 1 }
            while true {
                guard let afterValue = skipJSONValue(bytes, from: i) else { return nil }
                i = skipWhitespace(bytes, from: afterValue)
                guard i < bytes.count else { return nil }
                if bytes[i] == UInt8(ascii: ",") {
                    i = skipWhitespace(bytes, from: i + 1)
                    continue
                }
                if bytes[i] == UInt8(ascii: "]") { return i + 1 }
                return nil
            }

        case UInt8(ascii: "t"):
            return matchLiteral(bytes, from: start, literal: "true")
        case UInt8(ascii: "f"):
            return matchLiteral(bytes, from: start, literal: "false")
        case UInt8(ascii: "n"):
            return matchLiteral(bytes, from: start, literal: "null")

        default:
            return scanNumberToken(bytes, from: start)
        }
    }

    static func matchLiteral(_ bytes: [UInt8], from start: Int, literal: String) -> Int? {
        let literalBytes = Array(literal.utf8)
        let end = start + literalBytes.count
        guard end <= bytes.count, Array(bytes[start..<end]) == literalBytes else { return nil }
        return end
    }

    /// Scans a JSON string literal starting at the opening `"` at `start`,
    /// decoding standard JSON escapes (including `\uXXXX` and surrogate
    /// pairs), so escaped keys/values are compared and skipped correctly.
    /// Returns the decoded UTF-8 bytes and the index just past the closing
    /// `"`, or `nil` if the string is unterminated or contains an invalid
    /// escape.
    static func scanStringLiteral(_ bytes: [UInt8], from start: Int) -> ([UInt8], Int)? {
        var i = start + 1
        var out: [UInt8] = []
        while true {
            guard i < bytes.count else { return nil }
            let b = bytes[i]
            if b == UInt8(ascii: "\"") {
                return (out, i + 1)
            }
            if b == UInt8(ascii: "\\") {
                i += 1
                guard i < bytes.count else { return nil }
                switch bytes[i] {
                case UInt8(ascii: "\""): out.append(UInt8(ascii: "\"")); i += 1
                case UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\")); i += 1
                case UInt8(ascii: "/"): out.append(UInt8(ascii: "/")); i += 1
                case UInt8(ascii: "b"): out.append(0x08); i += 1
                case UInt8(ascii: "f"): out.append(0x0C); i += 1
                case UInt8(ascii: "n"): out.append(0x0A); i += 1
                case UInt8(ascii: "r"): out.append(0x0D); i += 1
                case UInt8(ascii: "t"): out.append(0x09); i += 1
                case UInt8(ascii: "u"):
                    guard let (unit, afterUnit) = readHex4(bytes, from: i + 1) else { return nil }
                    i = afterUnit
                    var scalarValue = UInt32(unit)
                    if unit >= 0xD800, unit <= 0xDBFF {
                        guard i + 1 < bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u"),
                              let (low, afterLow) = readHex4(bytes, from: i + 2), low >= 0xDC00, low <= 0xDFFF
                        else {
                            return nil
                        }
                        scalarValue = 0x10000 + (UInt32(unit) - 0xD800) * 0x400 + (UInt32(low) - 0xDC00)
                        i = afterLow
                    } else if unit >= 0xDC00, unit <= 0xDFFF {
                        return nil
                    }
                    guard let scalar = Unicode.Scalar(scalarValue) else { return nil }
                    out.append(contentsOf: Array(String(scalar).utf8))
                default:
                    return nil
                }
            } else if b < 0x20 {
                return nil
            } else {
                out.append(b)
                i += 1
            }
        }
    }

    static func readHex4(_ bytes: [UInt8], from start: Int) -> (UInt16, Int)? {
        guard start + 4 <= bytes.count else { return nil }
        var value: UInt16 = 0
        for offset in 0..<4 {
            guard let digit = hexDigitValue(bytes[start + offset]) else { return nil }
            value = value << 4 | UInt16(digit)
        }
        return (value, start + 4)
    }

    static func hexDigitValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    /// Matches the strict JSON number grammar (RFC 8259 §6):
    /// `-? (0 | [1-9][0-9]*) (.[0-9]+)? ([eE][+-]?[0-9]+)?`, returning the
    /// index just past the token, or `nil` if the bytes at `start` don't
    /// form a valid JSON number.
    static func scanNumberToken(_ bytes: [UInt8], from start: Int) -> Int? {
        var i = start
        guard i < bytes.count else { return nil }
        if bytes[i] == UInt8(ascii: "-") { i += 1 }
        guard i < bytes.count else { return nil }

        if bytes[i] == UInt8(ascii: "0") {
            i += 1
        } else if bytes[i] >= UInt8(ascii: "1"), bytes[i] <= UInt8(ascii: "9") {
            i += 1
            while i < bytes.count, bytes[i] >= UInt8(ascii: "0"), bytes[i] <= UInt8(ascii: "9") { i += 1 }
        } else {
            return nil
        }

        if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
            var j = i + 1
            guard j < bytes.count, bytes[j] >= UInt8(ascii: "0"), bytes[j] <= UInt8(ascii: "9") else { return nil }
            while j < bytes.count, bytes[j] >= UInt8(ascii: "0"), bytes[j] <= UInt8(ascii: "9") { j += 1 }
            i = j
        }

        if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
            var j = i + 1
            if j < bytes.count, bytes[j] == UInt8(ascii: "+") || bytes[j] == UInt8(ascii: "-") { j += 1 }
            guard j < bytes.count, bytes[j] >= UInt8(ascii: "0"), bytes[j] <= UInt8(ascii: "9") else { return nil }
            while j < bytes.count, bytes[j] >= UInt8(ascii: "0"), bytes[j] <= UInt8(ascii: "9") { j += 1 }
            i = j
        }

        return i
    }

    // MARK: - Decimal classification of the version number token
    //
    // Classifies an already-grammar-validated JSON number token's exact
    // decimal magnitude using only string/character arithmetic — never
    // `Double` (which can't represent `1e309` or a 500-digit integer) and
    // never `Int` (which traps or overflows on the same inputs).

    /// The number of exponent digits above which the exponent's magnitude
    /// is guaranteed to dwarf any realistic fractional-digit count derived
    /// from bytes actually read from disk, letting classification avoid
    /// parsing the exponent into an `Int` at all for such tokens. 18 digits
    /// safely fits in `Int64` (max ~9.22e18) with headroom to spare.
    static let maxParsableExponentDigitCount = 18

    static func classifyVersionNumberToken(_ token: String, currentVersion: Int) -> Result {
        let remainder = Substring(token)
        guard remainder.first != "-" else {
            // A negative version has no meaning and no migration path.
            return .invalid
        }

        var mantissaPart = remainder
        var exponentDigits: Substring = ""
        var exponentIsNegative = false
        if let eIndex = remainder.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissaPart = remainder[remainder.startIndex..<eIndex]
            var expToken = remainder[remainder.index(after: eIndex)...]
            if expToken.first == "+" {
                expToken = expToken.dropFirst()
            } else if expToken.first == "-" {
                exponentIsNegative = true
                expToken = expToken.dropFirst()
            }
            exponentDigits = expToken
        }

        var integerPart = mantissaPart
        var fractionPart: Substring = ""
        if let dotIndex = mantissaPart.firstIndex(of: ".") {
            integerPart = mantissaPart[mantissaPart.startIndex..<dotIndex]
            fractionPart = mantissaPart[mantissaPart.index(after: dotIndex)...]
        }

        let mantissaDigits = Array(integerPart) + Array(fractionPart)
        let mantissaIsZero = mantissaDigits.allSatisfy { $0 == "0" }
        let fractionDigitCount = fractionPart.count

        let integerDigits: [Character]
        if exponentDigits.count > maxParsableExponentDigitCount {
            if exponentIsNegative {
                // The exponent's magnitude vastly exceeds any realistic
                // fractional-digit count read from disk, so the value
                // collapses toward (or exactly to) zero: never a valid
                // positive integral version.
                return .invalid
            }
            if mantissaIsZero {
                // 0 * 10^(huge) is exactly zero, not a valid version.
                return .invalid
            }
            // The exponent's magnitude vastly exceeds the fractional
            // digit count, so the value is unambiguously integral and
            // astronomically larger than anything this build supports.
            return .future(token)
        }

        let exponentValue = exponentDigits.isEmpty ? 0 : (Int(exponentDigits) ?? 0)
        let signedExponent = exponentIsNegative ? -exponentValue : exponentValue
        let shift = signedExponent - fractionDigitCount

        if shift >= 0 {
            integerDigits = mantissaDigits + Array(repeating: Character("0"), count: shift)
        } else {
            let shiftMagnitude = -shift
            guard shiftMagnitude < mantissaDigits.count else {
                // The decimal point falls at or before the start of the
                // mantissa: even when the whole value collapses exactly to
                // zero, that's still not a valid version (versions start
                // at 1); otherwise it's a non-zero fraction, also invalid.
                return .invalid
            }
            let splitIndex = mantissaDigits.count - shiftMagnitude
            let tail = mantissaDigits[splitIndex...]
            guard tail.allSatisfy({ $0 == "0" }) else {
                // Non-zero digits after the decimal point: not integral.
                return .invalid
            }
            integerDigits = Array(mantissaDigits[..<splitIndex])
        }

        let normalized = trimLeadingZeros(integerDigits)
        guard !normalized.isEmpty else {
            // Value is exactly zero; versions start at 1.
            return .invalid
        }

        let currentVersionDigits = Array(String(currentVersion))
        if normalized.count != currentVersionDigits.count {
            return normalized.count > currentVersionDigits.count ? .future(token) : .invalid
        }
        if normalized.elementsEqual(currentVersionDigits) {
            return .supported
        }
        return normalized.lexicographicallyPrecedes(currentVersionDigits) ? .invalid : .future(token)
    }

    static func trimLeadingZeros(_ digits: [Character]) -> [Character] {
        var start = digits.startIndex
        while start < digits.index(before: digits.endIndex), digits[start] == "0" {
            start += 1
        }
        let trimmed = digits[start...]
        return trimmed == ["0"] ? [] : Array(trimmed)
    }
}

public actor AtomicJSONStore<Document: VersionedDocument> {
    private let fileURL: URL
    private let fileSystem: SettingsFileSystem
    private let clock: Clock
    private var writesEnabled = true

    /// Serializes every public `load()`/`save(_:)` call through its full
    /// awaited I/O and `writesEnabled` publication, in FIFO invocation
    /// order. Without this, actor reentrancy across the `await`s inside
    /// `load`/`save` would let a later call observe or mutate state (disk
    /// bytes, `writesEnabled`) mid-operation of an earlier call.
    private let gate = AsyncGate()

    public init(fileURL: URL, fileSystem: SettingsFileSystem, clock: Clock) {
        self.fileURL = fileURL
        self.fileSystem = fileSystem
        self.clock = clock
    }

    // MARK: - Load

    public func load() async -> LoadResult<Document> {
        await gate.acquire()
        let result = await performLoad()
        await gate.release()
        return result
    }

    private func performLoad() async -> LoadResult<Document> {
        let data: Data
        switch await readSourceFile() {
        case .missing:
            writesEnabled = true
            return LoadResult(value: Document.defaultValue, diagnostic: nil, writesEnabled: true)
        case .failed:
            writesEnabled = false
            let diagnostic = Diagnostic(
                id: StorageDiagnosticID.readFailed,
                message: "Could not read settings file at \(fileURL.path) (\(StorageError.readFailed)); using defaults without writing to disk.",
                occurredAt: clock.nowMilliseconds()
            )
            return LoadResult(value: Document.defaultValue, diagnostic: diagnostic, writesEnabled: false)
        case .success(let bytes):
            data = bytes
        }

        switch probeVersion(in: data) {
        case .future(let description):
            writesEnabled = false
            let diagnostic = Diagnostic(
                id: StorageDiagnosticID.unsupportedVersion,
                message: "Settings file version \(description) is newer than the version \(Document.currentVersion) this build supports; using defaults without writing to disk.",
                occurredAt: clock.nowMilliseconds()
            )
            return LoadResult(value: Document.defaultValue, diagnostic: diagnostic, writesEnabled: false)

        case .invalid:
            return await quarantine(reason: .invalidVersion)

        case .supported:
            do {
                let document = try JSONDecoder().decode(Document.self, from: data)
                guard document.version == Document.currentVersion else {
                    return await quarantine(reason: .decodedVersionMismatch)
                }
                writesEnabled = true
                return LoadResult(value: document, diagnostic: nil, writesEnabled: true)
            } catch {
                return await quarantine(reason: .decodeFailed)
            }
        }
    }

    private enum ReadOutcome {
        case missing
        case failed
        case success(Data)
    }

    private func readSourceFile() async -> ReadOutcome {
        do {
            return .success(try await fileSystem.readFile(at: fileURL))
        } catch SettingsFileSystemError.fileNotFound {
            return .missing
        } catch {
            return .failed
        }
    }

    /// Inspects the top-level `version` field of `data` as raw JSON,
    /// without decoding the full document, so a future schema (which may
    /// have fields this build doesn't understand) can be safely detected
    /// and preserved untouched rather than misread as corrupt.
    ///
    /// Deliberately does not hand `data` to `JSONSerialization` while an
    /// arbitrarily large version number token is still present:
    /// `JSONSerialization` itself throws when a JSON number overflows
    /// `Double` (e.g. `1e309`), which would otherwise misreport a
    /// perfectly well-formed "future version" document as corrupt. Instead
    /// this lexically locates the top-level `version` number token by byte
    /// offset, classifies its magnitude using decimal-string arithmetic
    /// (never materializing it as `Double`/`Int`), and separately
    /// structurally validates the rest of the document by substituting a
    /// representable `0` for that one token before parsing.
    private func probeVersion(in data: Data) -> VersionProbing.Result {
        let bytes = [UInt8](data)
        switch VersionProbing.scanTopLevelVersionToken(in: bytes) {
        case .notFound, .nonNumericValue:
            return .invalid

        case .numberToken(let range):
            guard VersionProbing.isStructurallyValid(bytes: bytes, versionTokenRange: range) else {
                return .invalid
            }
            let token = String(decoding: bytes[range], as: UTF8.self)
            return VersionProbing.classifyVersionNumberToken(token, currentVersion: Document.currentVersion)
        }
    }


    private enum QuarantineReason {
        case invalidVersion
        case decodedVersionMismatch
        case decodeFailed
    }

    /// Moves the corrupt file at `fileURL` aside to a timestamped
    /// `.corrupt-<millis>` sibling (adding a deterministic numeric suffix on
    /// name collision) so it is never silently discarded.
    private func quarantine(reason: QuarantineReason) async -> LoadResult<Document> {
        let millis = clock.nowMilliseconds()
        let directory = fileURL.deletingLastPathComponent()
        let baseName = "\(fileURL.lastPathComponent).corrupt-\(millis)"

        var suffix = 0
        while true {
            let candidateName = suffix == 0 ? baseName : "\(baseName)-\(suffix)"
            let candidateURL = directory.appendingPathComponent(candidateName)
            do {
                try await fileSystem.moveItem(at: fileURL, to: candidateURL)
                writesEnabled = true
                let diagnostic = Diagnostic(
                    id: StorageDiagnosticID.corrupt,
                    message: "Settings file was corrupt (\(reason)) and has been quarantined to \(candidateName); using defaults.",
                    occurredAt: millis
                )
                return LoadResult(value: Document.defaultValue, diagnostic: diagnostic, writesEnabled: true)
            } catch SettingsFileSystemError.destinationAlreadyExists {
                suffix += 1
                continue
            } catch {
                writesEnabled = false
                let diagnostic = Diagnostic(
                    id: StorageDiagnosticID.quarantineFailed,
                    message: "Settings file was corrupt but could not be quarantined (\(StorageError.quarantineFailed)); using defaults without writing to disk.",
                    occurredAt: millis
                )
                return LoadResult(value: Document.defaultValue, diagnostic: diagnostic, writesEnabled: false)
            }
        }
    }

    // MARK: - Save

    /// Encodes `document` and atomically replaces the on-disk file with it:
    /// writes to a freshly named, unique sibling temp file, synchronizes it
    /// to durable storage, then atomically replaces (or moves into) the
    /// destination. The temp file is removed on any failure so no orphaned
    /// sibling is left behind.
    public func save(_ document: Document) async throws {
        await gate.acquire()
        do {
            try await performSave(document)
            await gate.release()
        } catch {
            await gate.release()
            throw error
        }
    }

    private func performSave(_ document: Document) async throws {
        guard writesEnabled else {
            throw StorageError.writesDisabled
        }
        guard document.version == Document.currentVersion else {
            throw StorageError.unsupportedVersion(document.version)
        }

        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(document)
        } catch {
            throw StorageError.encodeFailed
        }

        let directory = fileURL.deletingLastPathComponent()
        let tempURL = directory.appendingPathComponent("\(fileURL.lastPathComponent).tmp-\(UUID().uuidString)")

        do {
            try await fileSystem.ensureDirectoryExists(at: directory)
            try await fileSystem.writeFileAndSynchronize(data, to: tempURL)
            try await fileSystem.replaceItem(at: fileURL, withItemAt: tempURL)
        } catch {
            try? await fileSystem.removeItem(at: tempURL)
            throw StorageError.writeFailed
        }
    }
}
