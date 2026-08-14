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
}
