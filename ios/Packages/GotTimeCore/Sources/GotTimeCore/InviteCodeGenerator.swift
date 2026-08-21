import Foundation

/// Generates short, shareable invite codes (spec section 5: a private pairing code, never a
/// public directory or search). The alphabet deliberately excludes visually ambiguous
/// characters (I, O, 0, 1) so a code read aloud or handwritten doesn't get misread — matches
/// `connection_invites.invite_code`'s role: a discovery mechanism, not authentication, so
/// legibility matters more than raw entropy.
public enum InviteCodeGenerator {
    public static let length = 6
    private static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    public static func generate() -> String {
        String((0..<length).compactMap { _ in alphabet.randomElement() })
    }
}
