import AppKit
import SwiftUI

/// The row at the top of UniConnect's sidebar: the window controls on the leading
/// side, the sidebar's actions on the trailing side.
///
/// Both halves are drawn here, including the traffic lights — AppKit's are hidden
/// while this is on screen. That is what makes one layout serve every window
/// state: nothing in this row is positioned by the system, so the controls remain
/// locked to the sidebar card in a window, in full screen, and while the menu bar
/// slides down over it. Compact mode owns a separate root-level control row.
struct UniConnectSidebarHeader: View {
    /// Immutable unread-notification count for this render pass.
    let unreadCount: Int
    /// Window the traffic lights act on.
    let window: NSWindow?
    /// Opens the notifications popover, anchored to the bell.
    let onToggleNotifications: (NSView?) -> Void
    /// Starts the new-box flow.
    let onNewTab: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var notificationsAnchor = NotificationsAnchorReference()

    var body: some View {
        let palette = UniConnectSidebarHeaderPalette(
            colorScheme: colorScheme,
            reduceTransparency: reduceTransparency,
            increaseContrast: colorSchemeContrast == .increased
        )

        return HStack(spacing: 0) {
            UniConnectWindowControls(window: window)
                .padding(.leading, UniConnectSidebarHeaderMetrics.leadingInset)

            // Only the genuinely empty span is draggable. Keeping the drag view
            // as a sibling of both control groups prevents it from intercepting
            // the traffic lights, notification bell, or new-box button.
            WindowDragHandleView()
                .frame(minWidth: 12, maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("UniConnectSidebarHeaderDragRegion")

            cluster(palette: palette)
                .padding(.trailing, UniConnectSidebarHeaderMetrics.trailingInset)
        }
        .frame(height: UniConnectSidebarHeaderMetrics.rowHeight)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("UniConnectSidebarHeader")
    }

    private func cluster(palette: UniConnectSidebarHeaderPalette) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: UniConnectSidebarHeaderMetrics.clusterCornerRadius,
            style: .continuous
        )
        return HStack(spacing: 0) {
            notificationsButton(palette: palette)
            Rectangle()
                .fill(palette.clusterSeparator)
                .frame(
                    width: 1,
                    height: UniConnectSidebarHeaderMetrics.buttonHeight
                        * UniConnectSidebarHeaderMetrics.separatorHeightRatio
                )
                .allowsHitTesting(false)
            newBoxButton(palette: palette)
        }
        .padding(UniConnectSidebarHeaderMetrics.clusterPadding)
        .frame(height: UniConnectSidebarHeaderMetrics.clusterHeight)
        .background {
            if palette.isOpaque {
                shape.fill(palette.clusterOpaqueFill)
            } else {
                shape.fill(palette.clusterFill)
            }
        }
        .overlay(shape.strokeBorder(palette.clusterBorder, lineWidth: 0.5))
    }

    private func notificationsButton(palette: UniConnectSidebarHeaderPalette) -> some View {
        UniConnectSidebarActionButton(
            systemImage: "bell",
            accessibilityIdentifier: "titlebarControl.showNotifications",
            accessibilityLabel: String(
                localized: "titlebar.notifications.accessibilityLabel",
                defaultValue: "Notifications"
            ),
            palette: palette,
            accent: palette.notificationAccent,
            reduceMotion: reduceMotion,
            action: {
                #if DEBUG
                cmuxDebugLog("titlebar.notifications")
                #endif
                onToggleNotifications(notificationsAnchor.view)
            },
            overlay: {
                if let badgeText = Self.badgeText(unreadCount: unreadCount) {
                    Text(badgeText)
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 3)
                        .frame(
                            minWidth: UniConnectSidebarHeaderMetrics.badgeDiameter,
                            minHeight: UniConnectSidebarHeaderMetrics.badgeDiameter
                        )
                        .background(
                            Capsule(style: .continuous)
                                .fill(palette.badgeFill)
                                .overlay(
                                    Capsule(style: .continuous).strokeBorder(
                                        palette.badgeRing,
                                        lineWidth: UniConnectSidebarHeaderMetrics.badgeRingWidth
                                    )
                                )
                        )
                        .offset(x: 5, y: -5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        )
        .accessibilityValue("\(unreadCount)")
        .safeHelp(
            KeyboardShortcutSettings.Action.showNotifications.tooltip(
                String(localized: "titlebar.notifications.tooltip", defaultValue: "Show notifications")
            )
        )
        .background(
            NotificationsAnchorView(preferredEdge: .maxY) { anchor in
                notificationsAnchor.view = anchor
            }
        )
    }

    private func newBoxButton(palette: UniConnectSidebarHeaderPalette) -> some View {
        UniConnectSidebarActionButton(
            systemImage: "plus",
            accessibilityIdentifier: "titlebarControl.newTab",
            accessibilityLabel: String(localized: "menu.file.newBox", defaultValue: "New Box…"),
            palette: palette,
            accent: palette.creationAccent,
            reduceMotion: reduceMotion,
            action: {
                #if DEBUG
                cmuxDebugLog("titlebar.newTab")
                #endif
                onNewTab()
            }
        )
        .safeHelp(
            KeyboardShortcutSettings.Action.newTab.tooltip(
                String(localized: "menu.file.newBox", defaultValue: "New Box…")
            )
        )
    }

    /// Formats an unread count for the badge, capping it at `99+`.
    static func badgeText(unreadCount: Int) -> String? {
        guard unreadCount > 0 else { return nil }
        return unreadCount > 99 ? "99+" : "\(unreadCount)"
    }

    /// Preserves the exact mounted AppKit anchor without making it observable:
    /// resolving an NSView is routing state, not SwiftUI presentation state.
    @MainActor
    private final class NotificationsAnchorReference {
        weak var view: NSView?
    }
}
