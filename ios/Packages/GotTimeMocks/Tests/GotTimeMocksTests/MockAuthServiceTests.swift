import XCTest
@testable import GotTimeMocks
import GotTimeCore

final class MockAuthServiceTests: XCTestCase {
    func testStartsSignedInByDefault() async {
        let service = MockAuthService()
        guard case .signedIn(let profile) = await service.currentState() else {
            return XCTFail("expected signed in")
        }
        XCTAssertEqual(profile.id, MockData.me.id)
    }

    func testCanStartSignedOut() async {
        let service = MockAuthService(startSignedIn: false)
        let state = await service.currentState()
        XCTAssertEqual(state, .signedOut)
    }

    func testSignOutThenSignInWithApple() async throws {
        let service = MockAuthService()
        try await service.signOut()
        var state = await service.currentState()
        XCTAssertEqual(state, .signedOut)

        try await service.signInWithApple()
        state = await service.currentState()
        guard case .signedIn = state else { return XCTFail("expected signed in after signInWithApple") }
    }

    func testDeleteAccountSignsOut() async throws {
        let service = MockAuthService()
        try await service.deleteAccount()
        let state = await service.currentState()
        XCTAssertEqual(state, .signedOut)
    }

    func testUpdateFirstNameWhileSignedIn() async throws {
        let service = MockAuthService()
        try await service.updateFirstName("Newname")
        guard case .signedIn(let profile) = await service.currentState() else {
            return XCTFail("expected signed in")
        }
        XCTAssertEqual(profile.firstName, "Newname")
    }

    func testUpdateFirstNameThrowsWhenSignedOut() async {
        let service = MockAuthService(startSignedIn: false)
        do {
            try await service.updateFirstName("Nope")
            XCTFail("expected notSignedIn to be thrown")
        } catch {
            XCTAssertEqual(error as? MockServiceError, .notSignedIn)
        }
    }

    func testAuthStateStreamEmitsCurrentStateImmediatelyThenChanges() async throws {
        let service = MockAuthService(startSignedIn: false)
        var collected: [AuthState] = []
        let collector = Task {
            for await state in service.authStateStream {
                collected.append(state)
                if collected.count == 2 { break }
            }
        }

        try await service.signInWithApple()
        await collector.value

        XCTAssertEqual(collected.count, 2)
        XCTAssertEqual(collected[0], .signedOut)
        guard case .signedIn = collected[1] else { return XCTFail("expected second emission to be signedIn") }
    }
}
