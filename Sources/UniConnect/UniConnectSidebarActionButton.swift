import SwiftUI

/// One action inside the sidebar header's grouped cluster.
///
/// The button owns only its interaction state; its resting appearance comes from
/// the cluster around it, so the pair reads as one grouped control rather than two
/// loose glyphs over the sidebar.
struct UniConnectSidebarActionButton<Overlay: View>: View {
    /// SF Symbol drawn as the glyph.
    let systemImage: String
    /// Stable identifier for UI tests.
    let accessibilityIdentifier: String
    /// Spoken label for assistive technology.
    let accessibilityLabel: String
    /// Resolved colours for the current appearance.
    let palette: UniConnectSidebarHeaderPalette
    /// Restrained accent revealed by hover and press.
    let accent: Color
    /// Whether the user asked for reduced motion.
    let reduceMotion: Bool
    /// Invoked on click.
    let action: () -> Void
    /// Decoration drawn over the glyph, such as an unread badge.
    @ViewBuilder var overlay: () -> Overlay

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    init(
        systemImage: String,
        accessibilityIdentifier: String,
        accessibilityLabel: String,
        palette: UniConnectSidebarHeaderPalette,
        accent: Color,
        reduceMotion: Bool,
        action: @escaping () -> Void,
        @ViewBuilder overlay: @escaping () -> Overlay = { EmptyView() }
    ) {
        self.systemImage = systemImage
        self.accessibilityIdentifier = accessibilityIdentifier
        self.accessibilityLabel = accessibilityLabel
        self.palette = palette
        self.accent = accent
        self.reduceMotion = reduceMotion
        self.action = action
        self.overlay = overlay
    }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: systemImage)
                    .font(.system(size: UniConnectSidebarHeaderMetrics.buttonIconSize, weight: .medium))
                    .frame(
                        width: UniConnectSidebarHeaderMetrics.buttonWidth,
                        height: UniConnectSidebarHeaderMetrics.buttonHeight
                    )
                overlay()
            }
            .frame(
                width: UniConnectSidebarHeaderMetrics.buttonWidth,
                height: UniConnectSidebarHeaderMetrics.buttonHeight
            )
        }
        .buttonStyle(
            UniConnectSidebarActionButtonStyle(
                palette: palette,
                accent: accent,
                reduceMotion: reduceMotion,
                isHovering: isHovering
            )
        )
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityLabel(accessibilityLabel)
        // The header sits in the window's titlebar band, which routes window drag
        // and double-click-zoom. Registering the region makes that routing yield.
        .titlebarInteractiveControl()
    }
}
