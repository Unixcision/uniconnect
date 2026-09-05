import AppKit
import SwiftUI
import UniConnectClaudeBridge

/// A snapshot-only squircle row for UniConnect's compact sidebar rail.
struct UniConnectRailTile: View, Equatable {
    let snapshot: UniConnectChipSnapshot
    let actions: UniConnectChipActions

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    nonisolated static func == (lhs: UniConnectRailTile, rhs: UniConnectRailTile) -> Bool {
        lhs.snapshot == rhs.snapshot
    }

    private var chipSize: CGFloat { UniConnectRailSidebar.tileSize }

    private var baseColor: NSColor {
        WorkspaceTabColorSettings.displayNSColor(
            hex: snapshot.colorHex,
            colorScheme: colorScheme
        ) ?? NSColor(hex: snapshot.colorHex) ?? .controlAccentColor
    }

    private var color: Color { Color(nsColor: baseColor) }

    private var isWindowActive: Bool {
        controlActiveState != .inactive
    }

    private var chipOpacity: Double {
        if colorSchemeContrast == .increased {
            if snapshot.isDisconnected { return 0.72 }
            if snapshot.isSelected { return 1 }
            if isHovered || isFocused { return 0.96 }
            return isWindowActive ? 0.84 : 0.76
        }
        if snapshot.isDisconnected { return 0.52 }
        if snapshot.isSelected { return isWindowActive ? 1 : 0.82 }
        if isHovered || isFocused { return isWindowActive ? 0.90 : 0.72 }
        return isWindowActive ? 0.64 : 0.52
    }

    private var chipScale: CGFloat {
        if reduceMotion { return 1 }
        if snapshot.isSelected { return 1 }
        if isHovered { return 0.98 }
        return 0.92
    }

    private var chipSaturation: Double {
        guard snapshot.isDisconnected || !isWindowActive else { return 1 }
        return colorSchemeContrast == .increased ? 0.82 : 0.55
    }

    private var cornerRadius: CGFloat {
        chipSize * (snapshot.isSelected ? 0.40 : 0.30)
    }

    private var glyphColor: Color {
        Color(
            nsColor: UniConnectRailPalette.identityForegroundNSColor(
                baseColor: baseColor,
                layerOpacity: CGFloat(chipOpacity),
                gradientOpacity: UniConnectRailPalette.railGradientMidpointOpacity,
                surfaceColor: UniConnectRailPalette.windowBackgroundNSColor(for: colorScheme)
            )
        )
    }

    var body: some View {
        Button(action: activateBox) {
            ZStack {
                groupDeck
                    .opacity(chipOpacity)
                    .saturation(chipSaturation)
                squircle
                    .opacity(chipOpacity)
                    .saturation(chipSaturation)
                identity
            }
            .frame(width: chipSize, height: chipSize)
            .overlay(alignment: .topTrailing) { unreadBadge }
            .overlay(alignment: .bottomTrailing) { connectionBadge }
            .overlay(alignment: .bottomLeading) { statusBadge }
            .overlay { focusRing }
            .scaleEffect(chipScale)
            .shadow(
                color: snapshot.isSelected ? Color.black.opacity(colorScheme == .dark ? 0.32 : 0.16) : .clear,
                radius: 5,
                y: 2
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: snapshot.isSelected)
            .animation(reduceMotion ? nil : .snappy(duration: 0.16), value: isHovered)
        }
        .buttonStyle(UniConnectRailButtonStyle(reduceMotion: reduceMotion))
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .background(
            UniConnectSidebarFlyoutAnchor(
                snapshot: snapshot,
                actions: actions,
                isFocused: isFocused,
                reduceMotion: reduceMotion,
                reduceTransparency: reduceTransparency,
                colorScheme: colorScheme,
                colorSchemeContrast: colorSchemeContrast
            )
        )
        .contextMenu { contextMenu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot.displayName)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(snapshot.isSelected ? [.isSelected, .isButton] : [.isButton])
        .accessibilityAction(
            named: Text(
                String(
                    localized: "uniconnect.rail.flyout.showWindows",
                    defaultValue: "Show Window List"
                )
            )
        ) {
            presentWindowList()
        }
        .accessibilityAction(
            named: Text(renameItemLabel)
        ) {
            actions.renameBox()
        }
        .accessibilityAction(
            named: Text(closeItemLabel)
        ) {
            actions.closeBox()
        }
        .accessibilityIdentifier("UniConnectRailTile-\(snapshot.id.uuidString)")
    }

    private var squircle: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        color.opacity(UniConnectRailPalette.railGradientStartOpacity),
                        color.opacity(UniConnectRailPalette.railGradientEndOpacity),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        Color.primary.opacity(
                            colorSchemeContrast == .increased
                                ? (snapshot.isSelected ? 0.48 : 0.30)
                                : (snapshot.isSelected ? 0.28 : (colorScheme == .dark ? 0.14 : 0.18))
                        ),
                        lineWidth: colorSchemeContrast == .increased
                            ? (snapshot.isSelected ? 1.6 : 1.2)
                            : (snapshot.isSelected ? 1.2 : 0.8)
                    )
            }
    }

    @ViewBuilder
    private var groupDeck: some View {
        if snapshot.isGroup {
            RoundedRectangle(cornerRadius: chipSize * 0.28, style: .continuous)
                .fill(color.opacity(0.18))
                .frame(width: chipSize - 2, height: chipSize - 2)
                .offset(x: 4, y: -4)
            RoundedRectangle(cornerRadius: chipSize * 0.29, style: .continuous)
                .fill(color.opacity(0.34))
                .frame(width: chipSize - 1, height: chipSize - 1)
                .offset(x: 2, y: -2)
        }
    }

    @ViewBuilder
    private var identity: some View {
        if let symbolName = snapshot.symbolName, !symbolName.isEmpty {
            Image(systemName: symbolName)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(glyphColor)
        } else {
            Text(snapshot.monogram)
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .tracking(-0.45)
                .foregroundStyle(glyphColor)
                .minimumScaleFactor(0.72)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var unreadBadge: some View {
        if snapshot.unreadCount > 0 {
            Text(snapshot.unreadCount > 9 ? "9+" : "\(snapshot.unreadCount)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 3.5)
                .frame(minWidth: 14, minHeight: 14)
                .background(Capsule().fill(UniConnectRailPalette.unread))
                .overlay(Capsule().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                .offset(x: 5, y: -5)
                .contentTransition(.numericText(value: Double(snapshot.unreadCount)))
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var connectionBadge: some View {
        Image(systemName: connectionSymbol)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(connectionBadgeForeground)
            .frame(width: 16, height: 16)
            .background(Circle().fill(connectionBadgeBackground))
            .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.2))
            .offset(x: 5, y: 5)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if snapshot.requiresLocalRootReassignment {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.orange))
                .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.2))
                .offset(x: -4, y: 5)
                .accessibilityHidden(true)
        } else if let bridgeStatus = snapshot.bridgeStatus {
            Image(systemName: bridgeStatus.uniConnectRailSymbolName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(bridgeStatus.uniConnectRailTint)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.black.opacity(colorSchemeContrast == .increased ? 0.92 : 0.74)))
                .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.2))
                .offset(x: -4, y: 5)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var focusRing: some View {
        if isFocused {
            RoundedRectangle(cornerRadius: cornerRadius + 3, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .padding(-3)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        if !snapshot.windows.isEmpty {
            Button(action: presentWindowList) {
                Label(
                    String(
                        localized: "uniconnect.rail.flyout.showWindows",
                        defaultValue: "Show Window List"
                    ),
                    systemImage: "macwindow.on.rectangle"
                )
            }
        }

        Button(action: actions.renameBox) {
            Label(renameItemLabel, systemImage: "pencil")
        }

        if let editSSHConnection = actions.editSSHConnection {
            Button(action: editSSHConnection) {
                Label(
                    String(localized: "contextMenu.editSSHConnection", defaultValue: "Edit SSH Connection…"),
                    systemImage: "network"
                )
            }
        }

        if let toggleGroup = actions.toggleGroup {
            Button(action: toggleGroup) {
                Label(
                    snapshot.isGroupCollapsed
                        ? String(localized: "workspaceGroup.expand.a11y", defaultValue: "Expand group")
                        : String(localized: "workspaceGroup.collapse.a11y", defaultValue: "Collapse group"),
                    systemImage: snapshot.isGroupCollapsed ? "chevron.down" : "chevron.up"
                )
            }
        }

        Button { actions.setPinned(!snapshot.isPinned) } label: {
            Label(
                pinItemLabel,
                systemImage: snapshot.isPinned ? "pin.slash" : "pin"
            )
        }

        if !snapshot.isGroup {
            Divider()

            Button(action: actions.createWindow) {
                Label(String(localized: "contextMenu.newTabInBox", defaultValue: "New Window"), systemImage: "plus.rectangle.on.rectangle")
            }
            if snapshot.windows.contains(where: \.canReconnectSSHNow) {
                Button(action: actions.reconnectSSHWindowsNow) {
                    Label(
                        String(
                            localized: "uniconnect.reconnect.box.now",
                            defaultValue: "Reconnect SSH Windows in This Box"
                        ),
                        systemImage: "arrow.clockwise"
                    )
                }
            }
            Button(action: actions.updateClaude) {
                Label(
                    String(localized: "contextMenu.updateClaudeInBox", defaultValue: "Update Claude in This Box…"),
                    systemImage: "arrow.down.app"
                )
            }
        } else if let editGroupConfiguration = actions.editGroupConfiguration {
            Divider()

            Button(action: editGroupConfiguration) {
                Label(
                    String(
                        localized: "workspaceGroup.contextMenu.editConfig",
                        defaultValue: "Edit Group Configuration…"
                    ),
                    systemImage: "gearshape"
                )
            }
        }

        Divider()

        if snapshot.canMarkRead {
            Button(action: actions.markRead) {
                Label(markReadItemLabel, systemImage: "envelope.open")
            }
        }
        if snapshot.canMarkUnread {
            Button(action: actions.markUnread) {
                Label(markUnreadItemLabel, systemImage: "envelope.badge")
            }
        }

        Divider()

        if let ungroup = actions.ungroup {
            Button(action: ungroup) {
                Label(
                    String(
                        localized: "workspaceGroup.contextMenu.ungroup",
                        defaultValue: "Ungroup (Keep Boxes)"
                    ),
                    systemImage: "rectangle.3.group"
                )
            }
        }

        Button(role: .destructive, action: actions.closeBox) {
            Label(closeItemLabel, systemImage: snapshot.isGroup ? "trash" : "xmark.square")
        }
    }

    private var renameItemLabel: String {
        snapshot.isGroup
            ? String(localized: "workspaceGroup.contextMenu.rename", defaultValue: "Rename Group…")
            : String(localized: "contextMenu.renameBox", defaultValue: "Rename Box…")
    }

    private var pinItemLabel: String {
        if snapshot.isGroup {
            return snapshot.isPinned
                ? String(localized: "workspaceGroup.contextMenu.unpin", defaultValue: "Unpin Group")
                : String(localized: "workspaceGroup.contextMenu.pin", defaultValue: "Pin Group")
        }
        return snapshot.isPinned
            ? String(localized: "contextMenu.unpinBox", defaultValue: "Unpin Box")
            : String(localized: "contextMenu.pinBox", defaultValue: "Pin Box")
    }

    private var markReadItemLabel: String {
        snapshot.isGroup
            ? String(localized: "notifications.markAsRead", defaultValue: "Mark as Read")
            : String(localized: "contextMenu.markBoxRead", defaultValue: "Mark Box as Read")
    }

    private var markUnreadItemLabel: String {
        snapshot.isGroup
            ? String(localized: "notifications.markAsUnread", defaultValue: "Mark as Unread")
            : String(localized: "contextMenu.markBoxUnread", defaultValue: "Mark Box as Unread")
    }

    private var closeItemLabel: String {
        snapshot.isGroup
            ? String(
                localized: "workspaceGroup.contextMenu.delete",
                defaultValue: "Delete Group (Close Boxes)"
            )
            : String(localized: "contextMenu.closeBox", defaultValue: "Close Box")
    }

    private var connectionSymbol: String {
        if snapshot.isDisconnected { return "network.slash" }
        if snapshot.isConnecting { return "arrow.clockwise" }
        switch snapshot.connectionKind {
        case .local: return "terminal"
        case .ssh: return "network"
        case .mixed: return "square.stack.3d.up"
        }
    }

    private var connectionBadgeForeground: Color {
        if snapshot.isDisconnected {
            return Color(nsColor: UniConnectRailPalette.compactDisconnectedForegroundNSColor)
        }
        return .white
    }

    private var connectionBadgeBackground: Color {
        if snapshot.isConnecting, !snapshot.isDisconnected { return .blue }
        return .black.opacity(
            UniConnectRailPalette.compactBadgeBackgroundOpacity(
                increasedContrast: colorSchemeContrast == .increased
            )
        )
    }

    private var accessibilityValue: String {
        let kind: String
        switch snapshot.connectionKind {
        case .local:
            kind = String(localized: "uniconnect.import.kind.local", defaultValue: "Local")
        case .ssh:
            kind = String(localized: "uniconnect.import.kind.ssh", defaultValue: "SSH")
        case .mixed:
            kind = String(localized: "uniconnect.rail.kind.mixed", defaultValue: "Mixed")
        }
        var values = [kind]
        values.append(windowCountAccessibilityLabel)
        if snapshot.unreadCount > 0 {
            values.append(String(
                format: String(localized: "workspaceGroup.unread.a11y", defaultValue: "%lld unread"),
                locale: .current,
                Int64(snapshot.unreadCount)
            ))
        }
        if snapshot.isDisconnected {
            values.append(String(localized: "remote.status.disconnected", defaultValue: "Disconnected"))
        }
        if snapshot.isConnecting {
            values.append(String(localized: "remote.status.connecting", defaultValue: "Connecting"))
        }
        if snapshot.requiresLocalRootReassignment {
            values.append(
                String(
                    localized: "uniconnect.localWindow.runtime.missingRoot",
                    defaultValue: "Box Folder Missing"
                )
            )
        }
        if let bridgeStatus = snapshot.bridgeStatus {
            values.append(bridgeStatus.uniConnectRailLocalizedLabel)
        }
        return values.joined(separator: ", ")
    }

    private var windowCountAccessibilityLabel: String {
        guard snapshot.windowCount != 1 else {
            return String(
                localized: "uniconnect.rail.accessibility.oneWindow",
                defaultValue: "1 window"
            )
        }
        return String(
            format: String(
                localized: "uniconnect.rail.accessibility.windowCount",
                defaultValue: "%lld windows"
            ),
            locale: .current,
            Int64(snapshot.windowCount)
        )
    }

    private func activateBox() {
        if snapshot.isGroup, NSEvent.modifierFlags.contains(.option), let toggleGroup = actions.toggleGroup {
            toggleGroup()
        } else {
            actions.selectBox()
            presentWindowList()
        }
    }

    private func presentWindowList() {
        actions.presentWindowList()
    }

}
