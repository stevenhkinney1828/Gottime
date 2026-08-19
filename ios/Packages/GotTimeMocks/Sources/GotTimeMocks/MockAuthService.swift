import Foundation
import GotTimeCore

/// Development-only AuthService. Real Sign in with Apple + Supabase Auth lands in Phase 2.
/// A plain class with explicit locking (not an actor) so `authStateStream` can satisfy
/// AuthService's synchronous `{ get }` requirement — actor-isolated properties require
/// `await` to access even for a stored value, which a non-async protocol requirement can't
/// accommodate. `@unchecked Sendable` is an honest label for that manual synchronization, not
/// a way around it.
public final class MockAuthService: AuthService, @unchecked Sendable {
    public let authStateStream: AsyncStream<AuthState>
    private let continuation: AsyncStream<AuthState>.Continuation
    private let lock = NSLock()
    private var state: AuthState
    private let mockProfile: Profile

    public init(startSignedIn: Bool = true, mockProfile: Profile = MockData.me) {
        let (stream, continuation) = AsyncStream<AuthState>.makeStream()
        self.authStateStream = stream
        self.continuation = continuation
        self.mockProfile = mockProfile
        self.state = startSignedIn ? .signedIn(mockProfile) : .signedOut
        continuation.yield(self.state)
    }

    private func setState(_ newState: AuthState) {
        lock.lock()
        state = newState
        lock.unlock()
        continuation.yield(newState)
    }

    public func currentState() async -> AuthState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    public func signInWithApple() async throws {
        setState(.signedIn(mockProfile))
    }

    public func signOut() async throws {
        setState(.signedOut)
    }

    public func deleteAccount() async throws {
        setState(.signedOut)
    }

    public func updateFirstName(_ firstName: String) async throws {
        guard case .signedIn(var profile) = await currentState() else {
            throw MockServiceError.notSignedIn
        }
        profile.firstName = firstName
        setState(.signedIn(profile))
    }
}
