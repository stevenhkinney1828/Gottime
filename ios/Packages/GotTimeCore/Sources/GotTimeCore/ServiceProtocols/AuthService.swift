import Foundation

public enum AuthState: Equatable, Sendable {
    case signedOut
    case signedIn(Profile)
}

/// Implemented by GotTimeMocks (development) and by a real Sign in with Apple + Supabase
/// Auth adapter (Phase 2). Never implemented by a SwiftUI view directly — views observe
/// `authStateStream` through a thin view model instead.
public protocol AuthService {
    /// Emits the current state immediately on subscription, then again on every change
    /// (including session expiry — spec section 16's "authentication expiration" case).
    var authStateStream: AsyncStream<AuthState> { get }

    func currentState() async -> AuthState
    func signInWithApple() async throws
    func signOut() async throws
    func deleteAccount() async throws
    func updateFirstName(_ firstName: String) async throws
}
