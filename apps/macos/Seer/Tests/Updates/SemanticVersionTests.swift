import XCTest
@testable import Seer

final class SemanticVersionTests: XCTestCase {
    // MARK: - Ordering

    func testMinorVersionOrdering() {
        let older = SemanticVersion.parse("1.2.3")
        let newer = SemanticVersion.parse("1.3.0")
        XCTAssertNotNil(older)
        XCTAssertNotNil(newer)
        XCTAssertLessThan(older!, newer!)
        XCTAssertFalse(newer! < older!)
    }

    func testMajorVersionOrdering() {
        XCTAssertLessThan(SemanticVersion.parse("1.9.9")!, SemanticVersion.parse("2.0.0")!)
    }

    func testPatchVersionOrdering() {
        XCTAssertLessThan(SemanticVersion.parse("1.2.3")!, SemanticVersion.parse("1.2.4")!)
    }

    func testPrereleaseIsLessThanItsOwnRelease() {
        let prerelease = SemanticVersion.parse("2.0.0-beta.1")
        let release = SemanticVersion.parse("2.0.0")
        XCTAssertNotNil(prerelease)
        XCTAssertNotNil(release)
        XCTAssertLessThan(prerelease!, release!)
        XCTAssertFalse(release! < prerelease!)
    }

    func testVPrefixParsesEqualToBareVersion() {
        let prefixed = SemanticVersion.parse("v1.2.3")
        let bare = SemanticVersion.parse("1.2.3")
        XCTAssertNotNil(prefixed)
        XCTAssertNotNil(bare)
        XCTAssertEqual(prefixed, bare)
    }

    func testUppercaseVPrefixAlsoParses() {
        XCTAssertEqual(SemanticVersion.parse("V1.2.3"), SemanticVersion.parse("1.2.3"))
    }

    func testEqualVersionsAreNeitherLessThanEachOther() {
        let a = SemanticVersion.parse("1.2.3")!
        let b = SemanticVersion.parse("1.2.3")!
        XCTAssertEqual(a, b)
        XCTAssertFalse(a < b)
        XCTAssertFalse(b < a)
    }

    func testBuildMetadataIsIgnoredForPrecedenceAndEquality() {
        XCTAssertEqual(SemanticVersion.parse("1.2.3+build.5"), SemanticVersion.parse("1.2.3"))
        XCTAssertFalse(SemanticVersion.parse("1.2.3+build.1")! < SemanticVersion.parse("1.2.3+build.999")!)
    }

    // MARK: - Pre-release identifier ordering

    func testNumericPrereleaseIdentifiersCompareNumerically() {
        XCTAssertLessThan(SemanticVersion.parse("1.0.0-alpha.2")!, SemanticVersion.parse("1.0.0-alpha.10")!)
    }

    func testNumericPrereleaseIdentifiersAlwaysLessThanAlphanumeric() {
        XCTAssertLessThan(SemanticVersion.parse("1.0.0-1")!, SemanticVersion.parse("1.0.0-alpha")!)
    }

    func testAlphanumericPrereleaseIdentifiersCompareLexically() {
        XCTAssertLessThan(SemanticVersion.parse("1.0.0-alpha")!, SemanticVersion.parse("1.0.0-beta")!)
    }

    func testShorterPrereleaseIdentifierListIsLessWhenPrefixesMatch() {
        XCTAssertLessThan(SemanticVersion.parse("1.0.0-alpha")!, SemanticVersion.parse("1.0.0-alpha.1")!)
    }

    func testNumericPrereleaseIdentifierWithLeadingZeroIsRejected() {
        XCTAssertNil(SemanticVersion.parse("1.0.0-01"))
    }

    // MARK: - Malformed tags rejected

    func testEmptyStringIsRejected() {
        XCTAssertNil(SemanticVersion.parse(""))
    }

    func testMissingPatchComponentIsRejected() {
        XCTAssertNil(SemanticVersion.parse("1.2"))
    }

    func testNonNumericComponentIsRejected() {
        XCTAssertNil(SemanticVersion.parse("1.two.3"))
    }

    func testTooManyDottedComponentsAreRejected() {
        XCTAssertNil(SemanticVersion.parse("1.2.3.4"))
    }

    func testTrailingDashWithNoPrereleaseIdentifierIsRejected() {
        XCTAssertNil(SemanticVersion.parse("1.2.3-"))
    }

    func testEmptyPrereleaseIdentifierIsRejected() {
        XCTAssertNil(SemanticVersion.parse("1.2.3-alpha..1"))
    }

    func testPrereleaseIdentifierWithInvalidCharacterIsRejected() {
        XCTAssertNil(SemanticVersion.parse("1.2.3-alpha_1"))
    }

    func testCompletelyUnstructuredStringIsRejected() {
        XCTAssertNil(SemanticVersion.parse("not-a-version"))
    }

    func testWhitespaceOnlyStringIsRejected() {
        XCTAssertNil(SemanticVersion.parse("   "))
    }

    func testBareVPrefixWithNothingElseIsRejected() {
        XCTAssertNil(SemanticVersion.parse("v"))
    }

    func testMalformedBuildMetadataIsRejected() {
        for tag in ["1.2.3+", "1.2.3+build..5", "1.2.3+bad_tag", "1.2.3+one+two"] {
            XCTAssertNil(SemanticVersion.parse(tag), "expected \(tag) to be rejected")
        }
    }

    func testCoreNumericComponentsWithLeadingZerosAreRejected() {
        for tag in ["01.2.3", "1.02.3", "1.2.03"] {
            XCTAssertNil(SemanticVersion.parse(tag), "expected \(tag) to be rejected")
        }
    }

    func testLeadingWhitespaceIsRejected() {
        XCTAssertNil(SemanticVersion.parse(" 1.2.3"))
        XCTAssertNil(SemanticVersion.parse("\t1.2.3"))
    }

    func testTrailingWhitespaceIsRejected() {
        XCTAssertNil(SemanticVersion.parse("1.2.3 "))
        XCTAssertNil(SemanticVersion.parse("1.2.3\n"))
    }

    func testLeadingAndTrailingWhitespaceIsRejected() {
        XCTAssertNil(SemanticVersion.parse("  1.2.3  "))
    }

    func testInternalWhitespaceIsStillRejected() {
        // Not whitespace padding — this exercises the pre-existing
        // "not a valid version at all" path, distinct from the new
        // whitespace-padding guard above.
        XCTAssertNil(SemanticVersion.parse("1.2 .3"))
    }

    // MARK: - Very large numeric identifiers (overflow-independent comparison)

    /// A syntactically valid major component one digit longer than
    /// `UInt64.max` (20 digits) — comfortably beyond even an unsigned
    /// 64-bit platform integer, let alone `Int`. SemVer places no upper
    /// bound on a numeric identifier's magnitude, so this must still
    /// parse successfully rather than being rejected as if it were
    /// malformed.
    private static let hugeMajor = "123456789012345678901234567890"

    func testVeryLargeMajorVersionParsesSuccessfully() {
        XCTAssertNotNil(SemanticVersion.parse("\(Self.hugeMajor).0.0"))
    }

    func testVeryLargeMajorVersionOrdersAboveAnOrdinaryVersion() {
        let huge = SemanticVersion.parse("\(Self.hugeMajor).0.0")!
        let ordinary = SemanticVersion.parse("999999999.0.0")!
        XCTAssertLessThan(ordinary, huge)
        XCTAssertFalse(huge < ordinary)
    }

    func testTwoVeryLargeMajorVersionsOfDifferingMagnitudeOrderByLength() {
        // Same leading digits, but one has an extra trailing digit —
        // proves comparison is not truncating/wrapping either value to a
        // bounded integer type (which could otherwise misorder these).
        let shorter = SemanticVersion.parse("\(Self.hugeMajor).0.0")!
        let longer = SemanticVersion.parse("\(Self.hugeMajor)9.0.0")!
        XCTAssertLessThan(shorter, longer)
    }

    func testTwoEqualVeryLargeMajorVersionsCompareEqual() {
        let a = SemanticVersion.parse("\(Self.hugeMajor).0.0")!
        let b = SemanticVersion.parse("\(Self.hugeMajor).0.0")!
        XCTAssertEqual(a, b)
        XCTAssertFalse(a < b)
        XCTAssertFalse(b < a)
    }

    func testVeryLargeNumericPrereleaseIdentifierParsesAndOrdersByMagnitude() {
        let smaller = SemanticVersion.parse("1.0.0-alpha.999999999999999999999")!
        let larger = SemanticVersion.parse("1.0.0-alpha.1000000000000000000000")!
        XCTAssertLessThan(smaller, larger)
        XCTAssertFalse(larger < smaller)
    }

    func testVeryLargeNumericPrereleaseIdentifierWithLeadingZeroIsStillRejected() {
        XCTAssertNil(SemanticVersion.parse("1.0.0-0123456789012345678901234567890"))
    }

    func testVeryLargeNumericPrereleaseIdentifierStillOrdersBeforeAlphanumeric() {
        let numeric = SemanticVersion.parse("1.0.0-123456789012345678901234567890")!
        let alphanumeric = SemanticVersion.parse("1.0.0-alpha")!
        XCTAssertLessThan(numeric, alphanumeric)
    }

    func testVeryLargeMinorAndPatchComponentsParseAndOrder() {
        let smallerMinor = SemanticVersion.parse("1.999999999999999999999.0")!
        let largerMinor = SemanticVersion.parse("1.1000000000000000000000.0")!
        XCTAssertLessThan(smallerMinor, largerMinor)

        let smallerPatch = SemanticVersion.parse("1.0.999999999999999999999")!
        let largerPatch = SemanticVersion.parse("1.0.1000000000000000000000")!
        XCTAssertLessThan(smallerPatch, largerPatch)
    }
}
