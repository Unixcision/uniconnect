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
    let colorSchemeContrast: ColorSchemeContrast
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
    @Environment(\.colorScheme) private var colorScheme
    @State private var isPointerInside = false
    @FocusState private var focusedTarget: FocusTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
                .layoutPriority(1)

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
        .modifier(
            UniConnectGlassCardBackground(
                cornerRadius: cornerRadius,
                reduceTransparency: reduceTransparency,
                increasedContrast: colorSchemeContrast == .increased
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(reduceTransparency ? 0.16 : 0.24), radius: 18, y: 7)
        .onHover { isInside in
            isPointerInside = isInside
            onHoverChanged(isInside || focusedTarget != nil)
        }
        .onChange(of: focusedTarget) { _, newTarget in
            onHoverChanged(isPointerInside || newTarget != nil)
        }
        .backport.onKeyPress(.escape) { _ in
            onDismiss()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(snapshot.displayName)
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier("UniConnectRailFlyout")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            identityMark

            VStack(alignment: .leading, spacing: 5) {
                Text(snapshot.displayName)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

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

                connectionAndBridgeStatuses
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
        ScrollView(.vertical) {
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
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.primary)
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
                            if let localActionMenu = window.localActionMenu,
                               localActionMenu.hasEnabledActions {
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

                        if let localActionMenu = window.localActionMenu,
                           localActionMenu.hasEnabledActions {
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
        .scrollIndicators(.automatic)
        .frame(maxHeight: CGFloat(min(snapshot.windows.count, 7)) * UniConnectSidebarFlyoutLayout.rowHeight)
    }

    private func onPerformSSHReconnect(_ workspaceID: UUID, _ panelID: UUID) {
        onReconnectSSHWindow(workspaceID, panelID)
    }

    private func badge(text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(
                    tint.opacity(
                        UniConnectRailPalette.badgeFillOpacity(
                            increasedContrast: colorSchemeContrast == .increased
                        )
                    )
                )
            )
            .overlay(
                Capsule().strokeBorder(
                    tint.opacity(colorSchemeContrast == .increased ? 0.52 : 0.22),
                    lineWidth: colorSchemeContrast == .increased ? 1 : 0.6
                )
            )
            .fixedSize()
    }

    @ViewBuilder
    private var connectionAndBridgeStatuses: some View {
        if snapshot.isConnecting {
            Label(
                String(localized: "remote.status.connecting", defaultValue: "Connecting"),
                systemImage: "arrow.clockwise"
            )
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(colorSchemeContrast == .increased ? Color.primary : Color.blue)
            .lineLimit(1)
        }

        if let bridgeStatus = snapshot.bridgeStatus {
            Label(
                bridgeStatus.uniConnectRailLocalizedLabel,
                systemImage: bridgeStatus.uniConnectRailSymbolName
            )
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(
                colorSchemeContrast == .increased
                    ? Color.primary
                    : bridgeStatus.uniConnectRailTint
            )
            .lineLimit(1)
        }
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
        if snapshot.isDisconnected {
            return Color(
                nsColor: UniConnectRailPalette.disconnectedBadgeNSColor(
                    for: colorScheme
                )
            )
        }
        return Color(
            nsColor: UniConnectRailPalette.connectionBadgeNSColor(
                for: snapshot.connectionKind,
                colorScheme: colorScheme
            )
        )
    }

    private var accessibilityValue: String {
        var components = [connectionLabel]
        if snapshot.isDisconnected {
            components.append(String(localized: "remote.status.disconnected", defaultValue: "Disconnected"))
        }
        if snapshot.isConnecting {
            components.append(String(localized: "remote.status.connecting", defaultValue: "Connecting"))
        }
        if let bridgeStatus = snapshot.bridgeStatus {
            components.append(bridgeStatus.uniConnectRailLocalizedLabel)
        }
        return components.joined(separator: ", ")
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
        let color = Color(nsColor: identityBaseColor)
        return ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            color.opacity(UniConnectRailPalette.flyoutGradientStartOpacity),
                            color.opacity(UniConnectRailPalette.flyoutGradientEndOpacity),
                        ],
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
        .foregroundStyle(identityForegroundColor)
        .frame(width: 38, height: 38)
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(identityForegroundColor.opacity(0.24), lineWidth: 0.8)
        )
        .accessibilityHidden(true)
    }

    private var identityBaseColor: NSColor {
        WorkspaceTabColorSettings.displayNSColor(
            hex: snapshot.colorHex,
            colorScheme: colorScheme
        ) ?? NSColor(hex: snapshot.colorHex) ?? .controlAccentColor
    }

    private var identityForegroundColor: Color {
        Color(
            nsColor: UniConnectRailPalette.identityForegroundNSColor(
                baseColor: identityBaseColor,
                layerOpacity: 1,
                gradientOpacity: UniConnectRailPalette.flyoutGradientMidpointOpacity,
                surfaceColor: UniConnectRailPalette.windowBackgroundNSColor(for: colorScheme)
            )
        )
    }
}
