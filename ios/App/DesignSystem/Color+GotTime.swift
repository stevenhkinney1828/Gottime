import SwiftUI
import UIKit

/// Semantic color tokens matching DESIGN_SYSTEM.md exactly. Defined in code via dynamic
/// UIColor providers rather than an Asset Catalog, since there's no Xcode available in this
/// environment to manage one — this is the standard, correct way to define adaptive colors
/// without one. Every token has both a light and dark value; neither is defined only inside
/// a dark-mode-specific branch.
extension Color {
    static func gtDynamic(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }

    static let gtBackground = gtDynamic(
        light: UIColor(red: 0.98, green: 0.97, blue: 0.95, alpha: 1),
        dark: UIColor(red: 0.08, green: 0.07, blue: 0.07, alpha: 1)
    )

    static let gtSurface = gtDynamic(
        light: UIColor.white,
        dark: UIColor(red: 0.14, green: 0.13, blue: 0.13, alpha: 1)
    )

    static let gtTextPrimary = gtDynamic(
        light: UIColor(red: 0.11, green: 0.10, blue: 0.10, alpha: 1),
        dark: UIColor(red: 0.95, green: 0.95, blue: 0.94, alpha: 1)
    )

    static let gtTextSecondary = gtDynamic(
        light: UIColor(red: 0.45, green: 0.42, blue: 0.40, alpha: 1),
        dark: UIColor(red: 0.65, green: 0.62, blue: 0.60, alpha: 1)
    )

    /// Muted warm terracotta — primary actions, selection.
    static let gtAccent = gtDynamic(
        light: UIColor(red: 0.72, green: 0.42, blue: 0.32, alpha: 1),
        dark: UIColor(red: 0.85, green: 0.55, blue: 0.45, alpha: 1)
    )

    static let gtTimerCalm = gtTextPrimary

    /// Warm amber — final 60 seconds and final 10 seconds. Never the *only* signal for
    /// timer state (DESIGN_SYSTEM.md) — always paired with a weight/size change.
    static let gtTimerWarning = gtDynamic(
        light: UIColor(red: 0.80, green: 0.52, blue: 0.14, alpha: 1),
        dark: UIColor(red: 0.95, green: 0.68, blue: 0.30, alpha: 1)
    )

    static let gtDestructive = gtDynamic(
        light: UIColor(red: 0.75, green: 0.25, blue: 0.22, alpha: 1),
        dark: UIColor(red: 0.90, green: 0.45, blue: 0.42, alpha: 1)
    )
}
