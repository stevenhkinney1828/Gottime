import XCTest
@testable import GotTimeCore

final class GotTimeCoreTests: XCTestCase {
    func testPackageNameIsSet() {
        XCTAssertEqual(GotTimeCore.packageName, "GotTimeCore")
    }
}
