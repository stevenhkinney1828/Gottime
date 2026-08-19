import XCTest
@testable import GotTimeMocks

final class GotTimeMocksTests: XCTestCase {
    func testPackageNameIsSet() {
        XCTAssertEqual(GotTimeMocks.packageName, "GotTimeMocks")
    }
}
