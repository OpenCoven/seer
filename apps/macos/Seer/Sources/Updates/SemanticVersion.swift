import Foundation

/// A parsed [Semantic Versioning 2.0.0](https://semver.org) version number,
/// used by `UpdateService` to decide whether a GitHub release tag is newer
/// than the running app's own version. Build metadata (a trailing
/// `+...` suffix) is accepted but discarded during parsing — per the spec,
/// it never participates in precedence — so it is not represented here at
/// all.
public struct SemanticVersion: Equatable, Sendable {
    /// A single dot-separated pre-release identifier. Per the SemVer spec,
    /// an identifier composed entirely of digits (and not empty) is
    /// compared numerically; any identifier containing a letter or hyphen
    /// is compared as a string, and always sorts *after* every numeric
    /// identifier regardless of its own text.
    public enum PrereleaseIdentifier: Equatable, Sendable {
        case numeric(Int)
        case alphanumeric(String)
    }

    public let major: Int
    public let minor: Int
    public let patch: Int
    /// Empty for a plain release (e.g. `1.2.3`); one entry per
    /// dot-separated identifier for a pre-release (e.g. `2.0.0-beta.1` →
    /// `[.alphanumeric("beta"), .numeric(1)]`).
    public let prerelease: [PrereleaseIdentifier]

    public init(major: Int, minor: Int, patch: Int, prerelease: [PrereleaseIdentifier] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    /// Parses `raw` as a semantic version, tolerating a single leading
    /// `v`/`V` (so GitHub's conventional `v1.2.3` tag and a bare `1.2.3`
    /// parse to an equal value) and a discarded `+build.metadata` suffix.
    /// Returns `nil` for anything that does not match `MAJOR.MINOR.PATCH`
    /// with all-numeric, non-empty major/minor/patch components and
    /// (if present) a non-empty, validly-formed dot-separated pre-release
    /// suffix — malformed release tags must never be silently misread as
    /// some arbitrary version instead of being rejected outright.
    public static func parse(_ raw: String) -> SemanticVersion? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let first = text.first, first == "v" || first == "V" {
            text.removeFirst()
        }
        guard !text.isEmpty else { return nil }

        // Build metadata never affects precedence, but it must still be
        // syntactically valid before being discarded.
        let buildParts = text.split(separator: "+", omittingEmptySubsequences: false)
        guard buildParts.count <= 2 else { return nil }
        if buildParts.count == 2 {
            let identifiers = buildParts[1].split(separator: ".", omittingEmptySubsequences: false)
            guard !identifiers.isEmpty,
                  identifiers.allSatisfy({
                      !$0.isEmpty && $0.allSatisfy { $0.isASCIIDigit || $0.isASCIILetter || $0 == "-" }
                  })
            else {
                return nil
            }
        }
        text = String(buildParts[0])
        guard !text.isEmpty else { return nil }

        let corePart: Substring
        let prereleasePart: Substring?
        if let dashIndex = text.firstIndex(of: "-") {
            corePart = text[text.startIndex..<dashIndex]
            prereleasePart = text[text.index(after: dashIndex)...]
        } else {
            corePart = Substring(text)
            prereleasePart = nil
        }

        let coreComponents = corePart.split(separator: ".", omittingEmptySubsequences: false)
        guard coreComponents.count == 3,
              let major = parseNumericComponent(coreComponents[0]),
              let minor = parseNumericComponent(coreComponents[1]),
              let patch = parseNumericComponent(coreComponents[2])
        else {
            return nil
        }

        var prerelease: [PrereleaseIdentifier] = []
        if let prereleasePart {
            guard !prereleasePart.isEmpty else { return nil }
            let identifierSubstrings = prereleasePart.split(separator: ".", omittingEmptySubsequences: false)
            for identifier in identifierSubstrings {
                guard let parsedIdentifier = parsePrereleaseIdentifier(identifier) else { return nil }
                prerelease.append(parsedIdentifier)
            }
        }

        return SemanticVersion(major: major, minor: minor, patch: patch, prerelease: prerelease)
    }

    /// A bare `MAJOR`/`MINOR`/`PATCH` component: non-empty, every character
    /// a digit, and no leading zero unless the component is exactly `"0"`
    /// itself — per the SemVer spec, `01.2.3` is not a valid version at
    /// all, so it must be rejected here rather than silently parsed as `1`.
    private static func parseNumericComponent(_ substring: Substring) -> Int? {
        guard !substring.isEmpty,
              substring.allSatisfy(\.isASCIIDigit),
              substring.count == 1 || substring.first != "0"
        else {
            return nil
        }
        return Int(substring)
    }

    /// A single pre-release identifier: non-empty, and composed only of
    /// ASCII alphanumerics and hyphens (the SemVer spec's allowed
    /// character set — no dots, since dots are already the separator). A
    /// digits-only identifier is numeric, unless it has a leading zero
    /// (e.g. `01`) — the spec never permits a leading zero on a numeric
    /// identifier, so such an identifier makes the whole tag malformed
    /// rather than being reinterpreted as some other kind of identifier.
    private static func parsePrereleaseIdentifier(_ substring: Substring) -> PrereleaseIdentifier? {
        guard !substring.isEmpty,
              substring.allSatisfy({ $0.isASCIIDigit || $0.isASCIILetter || $0 == "-" })
        else {
            return nil
        }

        if substring.allSatisfy(\.isASCIIDigit) {
            guard substring.count == 1 || substring.first != "0" else { return nil }
            guard let value = Int(substring) else { return nil }
            return .numeric(value)
        }

        return .alphanumeric(String(substring))
    }
}

extension SemanticVersion: Comparable {
    /// Orders two versions per SemVer §11's precedence rules: numeric
    /// major/minor/patch compared in order first; a version with no
    /// pre-release always outranks one with a pre-release at the same
    /// major.minor.patch (so `2.0.0-beta.1 < 2.0.0`); otherwise the
    /// pre-release identifier lists are compared position by position.
    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        if lhs.prerelease.isEmpty && rhs.prerelease.isEmpty { return false }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }

        let sharedCount = min(lhs.prerelease.count, rhs.prerelease.count)
        for index in 0..<sharedCount {
            let left = lhs.prerelease[index]
            let right = rhs.prerelease[index]
            if left == right { continue }
            switch (left, right) {
            case (.numeric(let leftValue), .numeric(let rightValue)):
                return leftValue < rightValue
            case (.numeric, .alphanumeric):
                return true
            case (.alphanumeric, .numeric):
                return false
            case (.alphanumeric(let leftValue), .alphanumeric(let rightValue)):
                return leftValue < rightValue
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
    var isASCIILetter: Bool { isASCII && isLetter }
}
