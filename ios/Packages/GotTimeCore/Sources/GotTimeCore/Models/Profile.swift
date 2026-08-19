import Foundation

/// Mirrors the `profiles` table. Deliberately minimal — no bio, no username, no public
/// profile fields (spec section 5).
public struct Profile: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public var firstName: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: UUID, firstName: String?, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.firstName = firstName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// True once onboarding (setting a first name) is complete. Sign in with Apple doesn't
    /// always supply a name, so this can't be assumed true just because a profile exists.
    public var hasCompletedOnboarding: Bool {
        guard let firstName else { return false }
        return !firstName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
