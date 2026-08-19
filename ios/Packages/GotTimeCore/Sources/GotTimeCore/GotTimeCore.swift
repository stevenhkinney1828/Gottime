/// Marker namespace for the GotTimeCore package.
///
/// GotTimeCore holds pure Swift business logic only: the call state machine, duration
/// validation, and timer math. It must never import SwiftUI, UIKit, CallKit, PushKit, or
/// AVFoundation — that boundary is what lets this package be exhaustively unit-tested and
/// keeps platform-integration bugs isolated to the App/Integrations layer.
public enum GotTimeCore {
    public static let packageName = "GotTimeCore"
}
