import XCTest
@testable import GotTimeCore

final class DurationPolicyTests: XCTestCase {
    // MARK: - Boundary matrix (spec section 19: "1 and 60 accepted; zero, >60, malformed values rejected")

    func testOneMinuteIsAccepted() {
        XCTAssertEqual(DurationPolicy.validateMinutes(1), .success(60))
    }

    func testSixtyMinutesIsAccepted() {
        XCTAssertEqual(DurationPolicy.validateMinutes(60), .success(3600))
    }

    func testZeroIsRejected() {
        XCTAssertEqual(DurationPolicy.validateMinutes(0), .failure(.tooShort(minutes: 0)))
    }

    func testNegativeIsRejected() {
        XCTAssertEqual(DurationPolicy.validateMinutes(-5), .failure(.tooShort(minutes: -5)))
    }

    func testSixtyOneIsRejected() {
        XCTAssertEqual(DurationPolicy.validateMinutes(61), .failure(.tooLong(minutes: 61)))
    }

    func testWayTooLongIsRejected() {
        XCTAssertEqual(DurationPolicy.validateMinutes(600), .failure(.tooLong(minutes: 600)))
    }

    func testEveryMinuteFromOneToSixtyIsAccepted() {
        for minutes in 1...60 {
            XCTAssertEqual(DurationPolicy.validateMinutes(minutes), .success(minutes * 60), "\(minutes) minutes")
        }
    }

    // MARK: - Presets

    func testAllPresetsAreValid() {
        for minutes in DurationPolicy.presetMinutes {
            guard case .success = DurationPolicy.validateMinutes(minutes) else {
                return XCTFail("preset \(minutes) should be valid")
            }
        }
    }

    func testPresetsMatchSpec() {
        XCTAssertEqual(DurationPolicy.presetMinutes, [5, 10, 15, 20, 30])
    }

    func testPresetSecondsMatchesOwnerRequestedShortOptions() {
        XCTAssertEqual(DurationPolicy.presetSeconds, [15, 30, 60, 180])
    }

    // MARK: - Custom text parsing (malformed input)

    func testParsesCleanIntegerText() {
        XCTAssertEqual(DurationPolicy.parseCustomMinutes("25"), .success(1500))
    }

    func testTrimsWhitespace() {
        XCTAssertEqual(DurationPolicy.parseCustomMinutes("  25  "), .success(1500))
    }

    func testRejectsDecimalInput() {
        XCTAssertEqual(DurationPolicy.parseCustomMinutes("5.5"), .failure(.notWholeMinutes))
    }

    func testRejectsNonNumericInput() {
        XCTAssertEqual(DurationPolicy.parseCustomMinutes("abc"), .failure(.notWholeMinutes))
    }

    func testRejectsEmptyInput() {
        XCTAssertEqual(DurationPolicy.parseCustomMinutes(""), .failure(.notWholeMinutes))
    }

    func testRejectsBlankInput() {
        XCTAssertEqual(DurationPolicy.parseCustomMinutes("   "), .failure(.notWholeMinutes))
    }

    func testCustomTextStillRespectsBounds() {
        XCTAssertEqual(DurationPolicy.parseCustomMinutes("0"), .failure(.tooShort(minutes: 0)))
        XCTAssertEqual(DurationPolicy.parseCustomMinutes("61"), .failure(.tooLong(minutes: 61)))
        XCTAssertEqual(DurationPolicy.parseCustomMinutes("1"), .success(60))
        XCTAssertEqual(DurationPolicy.parseCustomMinutes("60"), .success(3600))
    }

    func testRejectsUnitsOrExtraCharacters() {
        XCTAssertEqual(DurationPolicy.parseCustomMinutes("25 min"), .failure(.notWholeMinutes))
        XCTAssertEqual(DurationPolicy.parseCustomMinutes("25,"), .failure(.notWholeMinutes))
    }

    // MARK: - seconds(forMinutes:)

    func testSecondsConversion() {
        XCTAssertEqual(DurationPolicy.seconds(forMinutes: 10), 600)
        XCTAssertEqual(DurationPolicy.seconds(forMinutes: 1), 60)
    }
}
