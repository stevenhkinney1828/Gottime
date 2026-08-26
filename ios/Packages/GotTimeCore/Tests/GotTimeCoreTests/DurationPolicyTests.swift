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

    // MARK: - validateSeconds (the real 15-3600s floor/ceiling)

    func testFifteenSecondsIsAccepted() {
        XCTAssertEqual(DurationPolicy.validateSeconds(15), .success(15))
    }

    func testFourteenSecondsIsRejected() {
        XCTAssertEqual(DurationPolicy.validateSeconds(14), .failure(.outOfRange(seconds: 14)))
    }

    func testThirtySixHundredSecondsIsAccepted() {
        XCTAssertEqual(DurationPolicy.validateSeconds(3600), .success(3600))
    }

    func testThirtySixHundredOneSecondsIsRejected() {
        XCTAssertEqual(DurationPolicy.validateSeconds(3601), .failure(.outOfRange(seconds: 3601)))
    }

    // MARK: - parseCustomDuration (separate minutes + seconds fields, per the owner's own request
    // for arbitrary durations like "1 minute and 12 seconds," not just round minutes)

    func testParsesMinutesAndSecondsTogether() {
        XCTAssertEqual(DurationPolicy.parseCustomDuration(minutesText: "1", secondsText: "12"), .success(72))
    }

    func testSecondsOnlyFieldWithBlankMinutes() {
        XCTAssertEqual(DurationPolicy.parseCustomDuration(minutesText: "", secondsText: "45"), .success(45))
    }

    func testMinutesOnlyFieldWithBlankSeconds() {
        XCTAssertEqual(DurationPolicy.parseCustomDuration(minutesText: "5", secondsText: ""), .success(300))
    }

    func testBothFieldsBlankIsRejected() {
        XCTAssertEqual(DurationPolicy.parseCustomDuration(minutesText: "", secondsText: ""), .failure(.notWholeMinutes))
    }

    func testSecondsFieldMustBeUnderSixty() {
        XCTAssertEqual(DurationPolicy.parseCustomDuration(minutesText: "1", secondsText: "60"), .failure(.notWholeMinutes))
        XCTAssertEqual(DurationPolicy.parseCustomDuration(minutesText: "1", secondsText: "90"), .failure(.notWholeMinutes))
    }

    func testParseCustomDurationRejectsNonNumericInput() {
        XCTAssertEqual(DurationPolicy.parseCustomDuration(minutesText: "abc", secondsText: "12"), .failure(.notWholeMinutes))
        XCTAssertEqual(DurationPolicy.parseCustomDuration(minutesText: "1", secondsText: "5.5"), .failure(.notWholeMinutes))
    }

    func testParseCustomDurationBelowFifteenSecondsIsRejected() {
        XCTAssertEqual(DurationPolicy.parseCustomDuration(minutesText: "", secondsText: "10"), .failure(.outOfRange(seconds: 10)))
    }

    func testParseCustomDurationAboveSixtyMinutesIsRejected() {
        XCTAssertEqual(DurationPolicy.parseCustomDuration(minutesText: "61", secondsText: "0"), .failure(.outOfRange(seconds: 3660)))
    }

    // MARK: - formatDuration (the single display formatter, replacing several buggy ad hoc ones
    // that assumed whole minutes and silently showed "0 minutes" for anything under 60 seconds)

    func testFormatDurationUnderAMinute() {
        XCTAssertEqual(DurationPolicy.formatDuration(15), "15 seconds")
        XCTAssertEqual(DurationPolicy.formatDuration(1), "1 second")
    }

    func testFormatDurationExactMinutesOmitsZeroSeconds() {
        XCTAssertEqual(DurationPolicy.formatDuration(300), "5 minutes")
        XCTAssertEqual(DurationPolicy.formatDuration(60), "1 minute")
    }

    func testFormatDurationWithBothComponents() {
        XCTAssertEqual(DurationPolicy.formatDuration(72), "1 minute 12 seconds")
        XCTAssertEqual(DurationPolicy.formatDuration(125), "2 minutes 5 seconds")
    }
}
