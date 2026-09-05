import SwiftUI

/// Resolved colours for UniConnect's sidebar header, for one appearance and one
/// set of accessibility settings.
///
/// The actions share a single translucent surface rather than each carrying its
/// own, following Apple's guidance to group related custom controls onto one
/// surface and express the individual controls as concentric fills inside it.
struct UniConnectSidebarHeaderPalette: Equatable {
    /// Whether the cluster paints an opaque surface instead of a translucent one.
    let isOpaque: Bool
    private let isDark: Bool
    private let increaseContrast: Bool

    /// Builds the palette for the current environment.
    ///
    /// - Parameters:
    ///   - colorScheme: Appearance the header renders in.
    ///   - reduceTransparency: When `true`, the cluster drops translucency.
    ///   - increaseContrast: When `true`, fills and borders are strengthened.
    init(colorScheme: ColorScheme, reduceTransparency: Bool, increaseContrast: Bool) {
        self.isDark = colorScheme == .dark
        self.increaseContrast = increaseContrast
        self.isOpaque = reduceTransparency
    }

    /// Fill behind the whole action cluster.
    ///
    /// Faint on purpose: a blur material here reads as a flat milky slab over a
    /// dark sidebar, which is the opposite of the depth it is meant to suggest.
    var clusterFill: Color {
        if isDark {
            return Color(
                red: 5.0 / 255.0,
                green: 20.0 / 255.0,
                blue: 78.0 / 255.0
            )
            .opacity(increaseContrast ? 0.98 : 0.90)
        }
        return Color(
            red: 220.0 / 255.0,
            green: 228.0 / 255.0,
            blue: 247.0 / 255.0
        )
            .opacity(increaseContrast ? 0.98 : 0.88)
    }

    /// Solid equivalent used when Reduce Transparency is enabled.
    var clusterOpaqueFill: Color {
        isDark
            ? Color(red: 2.0 / 255.0, green: 10.0 / 255.0, blue: 51.0 / 255.0)
            : Color(red: 220.0 / 255.0, green: 228.0 / 255.0, blue: 247.0 / 255.0)
    }

    /// Hairline defining the cluster's edge.
    var clusterBorder: Color {
        if increaseContrast {
            return Color.primary.opacity(isDark ? 0.38 : 0.30)
        }
        return (isDark
            ? Color(red: 14.0 / 255.0, green: 101.0 / 255.0, blue: 214.0 / 255.0)
            : Color(red: 30.0 / 255.0, green: 24.0 / 255.0, blue: 223.0 / 255.0))
            .opacity(isDark ? 0.34 : 0.22)
    }

    /// Hairline between two adjacent buttons.
    var clusterSeparator: Color {
        Color.primary.opacity(increaseContrast ? 0.25 : (isDark ? 0.10 : 0.08))
    }

    /// Cool cyan used sparingly for the notification action's active state.
    var notificationAccent: Color {
        isDark
            ? Color(red: 11.0 / 255.0, green: 228.0 / 255.0, blue: 250.0 / 255.0)
            : Color(red: 14.0 / 255.0, green: 101.0 / 255.0, blue: 214.0 / 255.0)
    }

    /// Violet used sparingly for the creation action's active state.
    var creationAccent: Color {
        isDark
            ? Color(red: 195.0 / 255.0, green: 68.0 / 255.0, blue: 243.0 / 255.0)
            : Color(red: 90.0 / 255.0, green: 31.0 / 255.0, blue: 229.0 / 255.0)
    }

    /// Indigo badge fill with sufficient contrast against its white count.
    var badgeFill: Color {
        isDark
            ? Color(red: 90.0 / 255.0, green: 31.0 / 255.0, blue: 229.0 / 255.0)
            : Color(red: 30.0 / 255.0, green: 24.0 / 255.0, blue: 223.0 / 255.0)
    }

    /// Fill for one button in the given interaction state.
    ///
    /// Clear at rest: the cluster surface already separates the controls from the
    /// sidebar, so a resting per-button fill would read as a competing layer.
    func buttonFill(accent: Color, isHovering: Bool, isPressed: Bool) -> Color {
        if isPressed { return accent.opacity(isDark ? 0.25 : 0.16) }
        if isHovering { return accent.opacity(isDark ? 0.15 : 0.10) }
        return .clear
    }

    /// Glyph colour for the given interaction state.
    func buttonForeground(
        accent: Color,
        isHovering: Bool,
        isPressed: Bool,
        isEnabled: Bool
    ) -> Color {
        guard isEnabled else { return Color.primary.opacity(isDark ? 0.28 : 0.24) }
        if isHovering || isPressed { return accent }
        if increaseContrast {
            return Color.primary.opacity(0.92)
        }
        return Color.primary.opacity(0.78)
    }

    /// Colour of the ring lifting the unread badge off the glyph behind it.
    var badgeRing: Color {
        isDark ? Color.black.opacity(0.55) : Color.white.opacity(0.85)
    }
}
