import AppKit
import SwiftUI
import UniConnectClaudeBridge

/// The one rich hover/focus card rendered above terminal portals in the host window.
struct UniConnectSidebarFlyoutView: View {
    private enum FocusTarget: Hashable {
        case window(UUID)
        case windowActions(UUID)
        case reconnect(UUID)
    }

    let snapshot: UniConnectChipSnapshot
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let onSelectWindow: (_ workspaceID: UUID, _ panelID: UUID) -> Void
    let onPerformLocalWindowAction: (
        _ workspaceID: UUID,
        _ panelID: UUID,
        _ action: UniConnectLocalWindowAction
    ) -> Void
    let onReconnectSSHWindow: (_ workspaceID: UUID, _ panelID: UUID) -> Void
    let onHoverChanged: (Bool) -> Void
    let onDismiss: () -> Void

    private let cornerRadius: CGFloat = 18
    @State private var isPointerInside = false
    @FocusState private var focusedTarget: FocusTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if snapshot.windows.isEmpty {
                Text(String(localized: "uniconnect.rail.flyout.noWindows", defaultValue: "No windows yet"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5)
            } else {
                Divider().opacity(0.55)
                windowList
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(
            UniConnectGlassCardBackground(
                cornerRadius: cornerRadius,
                reduceTransparency: reduceTransparency
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(reduceTransparency ? 0.16 : 0.24), radius: 18, y: 7)
        .onHover { isInside in
            isPointerInside = isInside
            onHoverChanged(isInside || focusedTarget != nil)
        }
        .onChange(of: focusedTarget) { newTarget in
            onHoverChanged(isPointerInside || newTarget != nil)
        }
        .backport.onKeyPress(.escape) { _ in
            onDismiss()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("UniConnectRailFlyout")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            identityMark

            VStack(alignment: .leading, spacing: 5) {
                Text(snapshot.displayName)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let secondaryLabel = snapshot.secondaryLabel, !secondaryLabel.isEmpty {
                    Text(secondaryLabel)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack(spacing: 6) {
                    badge(
                        text: "\(snapshot.windowCount)",
                        systemImage: "macwindow.on.rectangle",
                        tint: .secondary
                    )
                    badge(
                        text: connectionLabel,
                        systemImage: connectionSymbol,
                        tint: connectionTint
                    )
                    if snapshot.unreadCount > 0 {
                        badge(
                            text: snapshot.unreadCount > 99 ? "99+" : "\(snapshot.unreadCount)",
                            systemImage: "bell.badge.fill",
                            tint: UniConnectRailPalette.unread
                        )
                    }
                }

                if let bridgeStatus = snapshot.bridgeStatus {
                    Label(bridgeStatus.uniConnectRailLocalizedLabel, systemImage: "bell.and.waves.left.and.right")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(bridgeStatus.uniConnectRailTint)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if let shortcutDigit = snapshot.shortcutDigit {
                Text("⌘\(shortcutDigit)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
        }
    }

    private var windowList: some View {
        ScrollView(.vertical, showsIndicators: snapshot.windows.count > 7) {
            LazyVStack(spacing: 3) {
                ForEach(snapshot.windows) { window in
                    HStack(spacing: 3) {
                        Button {
                            onSelectWindow(window.workspaceID, window.id)
                        } label: {
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                    .fill(windowIndicatorColor(window))
                                    .frame(width: 3, height: 15)

                                Image(systemName: windowSymbol(window))
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(
                                        window.isDisconnected || window.requiresLocalRootReassignment
                                            ? Color.orange
                                            : Color.secondary
                                    )
                                    .frame(width: 14)

                                Text(window.title)
                                    .font(.system(size: 11.5, weight: window.isFocused ? .semibold : .regular))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                Spacer(minLength: 4)

                                if window.isUnread {
                                    Circle()
                                        .fill(UniConnectRailPalette.unread)
                                        .frame(width: 6, height: 6)
                                        .accessibilityHidden(true)
                                }

                                if window.isFocused {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(Color(nsColor: NSColor(hex: snapshot.colorHex) ?? .controlAccentColor))
                                }
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 27)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(UniConnectFlyoutWindowButtonStyle(reduceMotion: reduceMotion))
                        .focused($focusedTarget, equals: .window(window.id))
                        .accessibilityLabel(windowAccessibilityLabel(window))
                        .accessibilityIdentifier("UniConnectRailFlyoutWindow-\(window.id.uuidString)")
                        .contextMenu {
                            if let localActionMenu = window.localActionMenu {
                                UniConnectLocalWindowActionMenu(
                                    snapshot: localActionMenu,
                                    onPerform: { action in
                                        onPerformLocalWindowAction(window.workspaceID, window.id, action)
                                    }
                                )
                            } else if window.canReconnectSSHNow {
                                Button {
                                    onPerformSSHReconnect(window.workspaceID, window.id)
                                } label: {
                                    Label(
                                        String(
                                            localized: "uniconnect.reconnect.window.now",
                                            defaultValue: "Reconnect This Window Now"
                                        ),
                                        systemImage: "arrow.clockwise"
                                    )
                                }
                            }
                        }

                        if let localActionMenu = window.localActionMenu {
                            Menu {
                                UniConnectLocalWindowActionMenu(
                                    snapshot: localActionMenu,
                                    onPerform: { action in
                                        onPerformLocalWindowAction(window.workspaceID, window.id, action)
                                    }
                                )
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 10, weight: .semibold))
                                    .frame(width: 20, height: 24)
                                    .contentShape(Rectangle())
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .focused($focusedTarget, equals: .windowActions(window.id))
                            .fixedSize()
                            .help(
                                String(
                                    localized: "uniconnect.localWindow.menu.moreActions",
                                    defaultValue: "More Window Actions"
                                )
                            )
                            .accessibilityLabel(
                                String(
                                    localized: "uniconnect.localWindow.menu.moreActions",
                                    defaultValue: "More Window Actions"
                                )
                            )
                        } else if window.canReconnectSSHNow {
                            Button {
                                onPerformSSHReconnect(window.workspaceID, window.id)
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 10, weight: .semibold))
                                    .frame(width: 20, height: 24)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .focused($focusedTarget, equals: .reconnect(window.id))
                            .help(
                                String(
                                    localized: "uniconnect.reconnect.window.now",
                                    defaultValue: "Reconnect This Window Now"
                                )
                            )
                            .accessibilityLabel(
                                String(
                                    localized: "uniconnect.reconnect.window.now",
                                    defaultValue: "Reconnect This Window Now"
                                )
                            )
                        }
                    }
                }
            }
        }
        .frame(maxHeight: CGFloat(min(snapshot.windows.count, 7)) * UniConnectSidebarFlyoutLayout.rowHeight)
    }

    private func onPerformSSHReconnect(_ workspaceID: UUID, _ panelID: UUID) {
        onReconnectSSHWindow(workspaceID, panelID)
    }

    private func badge(text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.12)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.22), lineWidth: 0.6))
            .fixedSize()
    }

    private var connectionLabel: String {
        switch snapshot.connectionKind {
        case .local:
            return String(localized: "uniconnect.import.kind.local", defaultValue: "Local").uppercased()
        case .ssh:
            return String(localized: "uniconnect.import.kind.ssh", defaultValue: "SSH")
        case .mixed:
            return String(localized: "uniconnect.rail.kind.mixed", defaultValue: "Mixed").uppercased()
        }
    }

    private var connectionSymbol: String {
        switch snapshot.connectionKind {
        case .local: return "desktopcomputer"
        case .ssh: return snapshot.isDisconnected ? "network.slash" : "network"
        case .mixed: return "square.stack.3d.up"
        }
    }

    private var connectionTint: Color {
        if snapshot.isDisconnected { return .orange }
        if snapshot.isConnecting { return .blue }
        return .secondary
    }

    private func windowIndicatorColor(_ window: UniConnectWindowSnapshot) -> Color {
        if window.requiresLocalRootReassignment { return .orange }
        if window.isUnread { return UniConnectRailPalette.unread }
        if window.isFocused {
            return Color(nsColor: NSColor(hex: snapshot.colorHex) ?? .controlAccentColor)
        }
        return Color.secondary.opacity(0.30)
    }

    private func windowSymbol(_ window: UniConnectWindowSnapshot) -> String {
        if window.requiresLocalRootReassignment { return "folder.badge.questionmark" }
        return window.isDisconnected ? "network.slash" : "macwindow"
    }

    private func windowAccessibilityLabel(_ window: UniConnectWindowSnapshot) -> String {
        var components = [window.title]
        if window.isFocused {
            components.append(String(localized: "settings.state.active", defaultValue: "Active"))
        }
        if window.isDisconnected {
            components.append(String(localized: "remote.status.disconnected", defaultValue: "Disconnected"))
        }
        if window.isUnread {
            components.append(String(localized: "uniconnect.rail.window.unread", defaultValue: "Unread activity"))
        }
        if window.requiresLocalRootReassignment {
            components.append(
                String(
                    localized: "uniconnect.localWindow.runtime.missingRoot",
                    defaultValue: "Box Folder Missing"
                )
            )
        }
        return components.joined(separator: ", ")
    }

    private var identityMark: some View {
        let color = Color(nsColor: NSColor(hex: snapshot.colorHex) ?? .controlAccentColor)
        return ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.98), color.opacity(0.74)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            if let symbolName = snapshot.symbolName, !symbolName.isEmpty {
                Image(systemName: symbolName)
                    .font(.system(size: 15, weight: .bold))
            } else {
                Text(snapshot.monogram)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .tracking(-0.4)
            }
        }
        .foregroundStyle(.white)
        .frame(width: 38, height: 38)
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.white.opacity(0.22), lineWidth: 0.8))
        .accessibilityHidden(true)
    }
}
