import XCTest
@testable import GotTimeCore

final class InviteCodeGeneratorTests: XCTestCase {
    func testGeneratesCodeOfTheExpectedLength() {
        XCTAssertEqual(InviteCodeGenerator.generate().count, InviteCodeGenerator.length)
    }

    func testEveryCharacterIsFromTheUnambiguousAlphabet() {
        let disallowed = CharacterSet(charactersIn: "IO01")
        for _ in 0..<200 {
            let code = InviteCodeGenerator.generate()
            for character in code.unicodeScalars {
                XCTAssertFalse(disallowed.contains(character), "\(code) contains an ambiguous character")
            }
            XCTAssertEqual(code, code.uppercased(), "\(code) should be all-uppercase")
        }
    }

    func testRepeatedCallsAreNotAllIdentical() {
        let codes = Set((0..<50).map { _ in InviteCodeGenerator.generate() })
        XCTAssertGreaterThan(codes.count, 1, "50 generated codes were all identical")
    }
}
