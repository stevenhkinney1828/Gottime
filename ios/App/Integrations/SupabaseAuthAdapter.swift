import AuthenticationServices
import CryptoKit
import Foundation
import GotTimeCore
import Supabase
import UIKit

enum SupabaseAuthAdapterError: Error {
    case missingIdentityToken
    case notSignedIn
}

/// Real Sign in with Apple + Supabase Auth (Phase 2), replacing MockAuthService outside
/// DEBUG/UI-test runs. Two bridging jobs live here: AuthenticationServices' delegate-based
/// `ASAuthorizationController` API into async/await (via `AppleSignInCoordinator` below), and
/// Supabase's own `authStateChanges` stream into `AuthService`'s `AsyncStream<AuthState>`
/// contract — the latter by re-fetching the `profiles` row on every signed-in transition rather
/// than trusting the Apple-supplied name cached in session/user metadata, since that would go
/// stale the moment `updateFirstName` is called and profiles, not auth metadata, is this app's
/// single source of truth for first_name.
public final class SupabaseAuthAdapter: NSObject, AuthService, @unchecked Sendable {
    private let client: SupabaseClient
    public let authStateStream: AsyncStream<AuthState>
    private let continuation: AsyncStream<AuthState>.Continuation
    // Unlike CallCoordinator's equivalent task properties, this class carries no @MainActor
    // (or any other) isolation, so there's no isolation domain for deinit to cross here —
    // a plain `var` is sufficient, not `nonisolated(unsafe)`.
    private var listenTask: Task<Void, Never>?

    public init(client: SupabaseClient) {
        self.client = client
        let (stream, continuation) = AsyncStream<AuthState>.makeStream()
        self.authStateStream = stream
        self.continuation = continuation
        super.init()

        listenTask = Task { [weak self] in
            guard let self else { return }
            for await (event, session) in self.client.auth.authStateChanges {
                switch event {
                case .initialSession, .signedIn, .userUpdated:
                    await self.emitState(for: session)
                case .signedOut, .userDeleted:
                    self.continuation.yield(.signedOut)
                case .passwordRecovery, .tokenRefreshed, .mfaChallengeVerified:
                    // Not used by this app (no MFA flow, no password-recovery email flow — Sign
                    // in with Apple is the only auth method) — listed explicitly rather than a
                    // catch-all `default:` so a future SDK case addition fails the build here
                    // instead of silently doing nothing.
                    break
                }
            }
        }
    }

    deinit {
        listenTask?.cancel()
    }

    private func emitState(for session: Session?) async {
        guard let user = session?.user else {
            continuation.yield(.signedOut)
            return
        }
        if let profile = try? await fetchProfile(userId: user.id) {
            continuation.yield(.signedIn(profile))
        } else {
            // The profiles row is created by the on_auth_user_created trigger (0001_profiles.sql)
            // in the same transaction as the auth.users insert, so this should be transient at
            // worst (a fetch racing that trigger) — surfacing signedOut here rather than a
            // partial/fake profile is the safer failure mode either way.
            continuation.yield(.signedOut)
        }
    }

    public func currentState() async -> AuthState {
        guard let user = client.auth.currentSession?.user else { return .signedOut }
        guard let profile = try? await fetchProfile(userId: user.id) else { return .signedOut }
        return .signedIn(profile)
    }

    @MainActor
    public func signInWithApple() async throws {
        let nonce = Self.randomNonceString()

        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName]
        request.nonce = Self.sha256(nonce)

        let credential = try await Self.performAppleIDRequest(request)

        guard
            let identityTokenData = credential.identityToken,
            let identityToken = String(data: identityTokenData, encoding: .utf8)
        else {
            throw SupabaseAuthAdapterError.missingIdentityToken
        }

        try await client.auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(provider: .apple, idToken: identityToken, nonce: nonce)
        )

        // Apple supplies the full name only on the very first authorization for a given user —
        // it will never come again on subsequent sign-ins. handle_new_user() (0001_profiles.sql)
        // already tries to seed first_name from raw_user_meta_data at signup, but that depends
        // on the name surviving the id-token exchange; setting it again here from the credential
        // Apple just handed back directly is the more reliable path and simply overwrites with
        // the same value in the case where both succeeded.
        if let givenName = credential.fullName?.givenName, !givenName.isEmpty {
            try? await updateFirstName(givenName)
        }
    }

    public func signOut() async throws {
        try await client.auth.signOut()
    }

    public func deleteAccount() async throws {
        // Deleting an auth.users row is an admin-only operation (service_role), never something
        // the client's own key can do — this invokes the delete-account Edge Function, which
        // verifies the caller's JWT and performs the deletion server-side. profiles and
        // everything else cascades from the auth.users delete (see the migrations' `on delete
        // cascade` foreign keys).
        try await client.functions.invoke("delete-account")
        try await client.auth.signOut()
    }

    public func updateFirstName(_ firstName: String) async throws {
        guard let userId = client.auth.currentSession?.user.id else {
            throw SupabaseAuthAdapterError.notSignedIn
        }
        try await client.from("profiles")
            .update(["first_name": firstName])
            .eq("id", value: userId)
            .execute()
        // A raw table UPDATE never fires Supabase's own authStateChanges (that stream is only
        // ever about auth session events — sign in/out/token refresh — never database row
        // writes), so without this, OnboardingView's Continue button would silently update the
        // database and then never advance: ContentView only switches away from OnboardingView
        // when a *new* authState arrives, and nothing here was producing one. Never caught by
        // mocked/UI testing because MockAuthService's own updateFirstName does call setState(),
        // masking the gap — this only surfaced on a real device, the first time a real account
        // ever went through onboarding with no name from Sign in with Apple. Re-fetching (not
        // constructing a Profile locally) matches this adapter's existing single-source-of-truth
        // philosophy for profiles (see the type's own doc comment above).
        if let profile = try? await fetchProfile(userId: userId) {
            continuation.yield(.signedIn(profile))
        }
    }

    private func fetchProfile(userId: UUID) async throws -> Profile {
        let row: ProfileRow = try await client.from("profiles")
            .select()
            .eq("id", value: userId)
            .single()
            .execute()
            .value
        return row.profile
    }
}

/// Mirrors the `profiles` table's actual (snake_case) column names explicitly, rather than
/// relying on a decoder's automatic case conversion being configured a particular way. Shared
/// (not `private`) since `SupabaseConnectionAdapter` needs the same row shape when resolving
/// the other participant in a connection.
struct ProfileRow: Decodable {
    let id: UUID
    let firstName: String?
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case firstName = "first_name"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var profile: Profile {
        Profile(id: id, firstName: firstName, createdAt: createdAt, updatedAt: updatedAt)
    }
}

// MARK: - Apple ID nonce helpers

extension SupabaseAuthAdapter {
    /// Matches Apple's own reference implementation for Sign in with Apple nonces closely —
    /// this exact approach (a securely-random string, its SHA256 hash sent as the request's
    /// nonce, the raw string sent to the auth provider for verification against that hash) is
    /// the standard, widely-documented pattern for preventing replay attacks on the identity
    /// token, not a project-specific invention.
    fileprivate static func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remainingLength = length

        while remainingLength > 0 {
            let randoms: [UInt8] = (0..<16).map { _ in
                var random: UInt8 = 0
                let errorCode = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
                if errorCode != errSecSuccess {
                    fatalError("Unable to generate nonce: SecRandomCopyBytes failed with OSStatus \(errorCode)")
                }
                return random
            }
            for random in randoms where remainingLength > 0 {
                if random < charset.count {
                    result.append(charset[Int(random)])
                    remainingLength -= 1
                }
            }
        }
        return result
    }

    fileprivate static func sha256(_ input: String) -> String {
        let hashed = SHA256.hash(data: Data(input.utf8))
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - ASAuthorizationController async bridge

extension SupabaseAuthAdapter {
    @MainActor
    fileprivate static func performAppleIDRequest(
        _ request: ASAuthorizationAppleIDRequest
    ) async throws -> ASAuthorizationAppleIDCredential {
        try await withCheckedThrowingContinuation { continuation in
            let coordinator = AppleSignInCoordinator(continuation: continuation)
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = coordinator
            controller.presentationContextProvider = coordinator
            coordinator.retain()
            controller.performRequests()
        }
    }
}

/// Bridges `ASAuthorizationControllerDelegate`'s callback API into a single Swift continuation.
/// `ASAuthorizationController` holds only a weak reference to its delegate, so this holds a
/// strong self-reference for the duration of exactly one request (`retain()`/`release()`),
/// rather than relying on the caller to keep it alive.
private final class AppleSignInCoordinator: NSObject, ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding
{
    private var continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>?
    private var selfRetain: AppleSignInCoordinator?

    init(continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>) {
        self.continuation = continuation
    }

    func retain() { selfRetain = self }
    private func release() { selfRetain = nil }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        defer { release() }
        if let credential = authorization.credential as? ASAuthorizationAppleIDCredential {
            continuation?.resume(returning: credential)
        } else {
            continuation?.resume(throwing: SupabaseAuthAdapterError.missingIdentityToken)
        }
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        defer { release() }
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? ASPresentationAnchor()
    }
}
