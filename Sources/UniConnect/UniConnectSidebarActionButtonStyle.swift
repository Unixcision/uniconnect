import SwiftUI

/// Press and hover treatment for ``UniConnectSidebarActionButton``.
struct UniConnectSidebarActionButtonStyle: ButtonStyle {
    /// Resolved colours for the current appearance.
    let palette: UniConnectSidebarHeaderPalette
    /// Restrained accent revealed by hover and press.
    let accent: Color
    /// Whether the user asked for reduced motion.
    let reduceMotion: Bool
    /// Whether the pointer is over the button.
    let isHovering: Bool

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = configuration.isPressed
        let shape = RoundedRectangle(
            cornerRadius: UniConnectSidebarHeaderMetrics.buttonCornerRadius,
            style: .continuous
        )
        return configuration.label
            .foregroundStyle(
                palette.buttonForeground(
                    accent: accent,
                    isHovering: isHovering,
                    isPressed: isPressed,
                    isEnabled: isEnabled
                )
            )
            .background(
                shape.fill(
                    palette.buttonFill(
                        accent: accent,
                        isHovering: isHovering,
                        isPressed: isPressed
                    )
                )
            )
            .contentShape(shape)
            .scaleEffect(reduceMotion ? 1 : (isPressed ? 0.94 : 1))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: isPressed)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: isHovering)
    }
}
