import AppKit
import SwiftUI
import UniConnectClaudeBridge

/// A snapshot-only squircle row for UniConnect's compact sidebar rail.
struct UniConnectRailTile: View, Equatable {
    let snapshot: UniConnectChipSnapshot
    let actions: UniConnectChipActions

    @Environment(\.colorScheme) private var colorScheme
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
        if snapshot.isDisconnected { return 0.45 }
        if snapshot.isSelected { return isWindowActive ? 1 : 0.82 }
        if isHovered || isFocused { return isWindowActive ? 0.90 : 0.72 }
        return isWindowActive ? 0.64 : 0.52
    }

    private var chipScale: CGFloat {
        if snapshot.isSelected { return 1 }
        if isHovered && !reduceMotion { return 0.98 }
        return 0.92
    }

    private var cornerRadius: CGFloat {
        chipSize * (snapshot.isSelected ? 0.40 : 0.30)
    }

    private var glyphColor: Color {
        Color(nsColor: cmuxReadableForegroundNSColor(on: baseColor, opacity: 0.96))
    }

    var body: some View {
        Button(action: activateBox) {
            ZStack {
                groupDeck
                squircle
                identity
            }
            .frame(width: chipSize, height: chipSize)
            .overlay(alignment: .topTrailing) { unreadBadge }
            .overlay(alignment: .bottomTrailing) { connectionBadge }
            .overlay(alignment: .bottomLeading) { statusBadge }
            .overlay { focusRing }
            .scaleEffect(chipScale)
            .opacity(chipOpacity)
            .saturation(snapshot.isDisconnected || !isWindowActive ? 0.55 : 1)
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
                reduceTransparency: reduceTransparency
            )
        )
        .contextMenu { contextMenu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot.displayName)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(snapshot.isSelected ? [.isSelected, .isButton] : [.isButton])
        .accessibilityAction(
            named: Text(String(localized: "contextMenu.renameBox", defaultValue: "Rename Box…"))
        ) {
            actions.renameBox()
        }
        .accessibilityAction(
            named: Text(String(localized: "contextMenu.closeBox", defaultValue: "Close Box"))
        ) {
            actions.closeBox()
        }
        .accessibilityIdentifier("UniConnectRailTile-\(snapshot.id.uuidString)")
    }

    private var squircle: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [color.opacity(1), color.opacity(0.78)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(snapshot.isSelected ? 0.28 : (colorScheme == .dark ? 0.12 : 0.18)),
                        lineWidth: snapshot.isSelected ? 1.2 : 0.8
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
                .font(.system(size: 8.5, weight: .bold, design: .rounded))
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
        if !snapshot.isGroup {
            Image(systemName: connectionSymbol)
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(snapshot.isDisconnected ? Color.orange : Color.white)
                .frame(width: 14, height: 14)
                .background(Circle().fill(Color.black.opacity(0.68)))
                .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.2))
                .offset(x: 4, y: 4)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if snapshot.requiresLocalRootReassignment {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 14, height: 14)
                .background(Circle().fill(Color.orange))
                .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.2))
                .offset(x: -3, y: 4)
                .accessibilityHidden(true)
        } else if let bridgeStatus = snapshot.bridgeStatus {
            Circle()
                .fill(bridgeStatus.uniConnectRailTint)
                .frame(width: 8, height: 8)
                .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.2))
                .offset(x: -2, y: 3)
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
        let renameShortcut = KeyboardShortcutSettings.shortcut(for: .renameWorkspace)
        let newSurfaceShortcut = KeyboardShortcutSettings.shortcut(for: .newSurface)
        let closeShortcut = KeyboardShortcutSettings.shortcut(for: .closeWorkspace)

        if let key = renameShortcut.keyEquivalent {
            Button(action: actions.renameBox) {
                Label(String(localized: "contextMenu.renameBox", defaultValue: "Rename Box…"), systemImage: "pencil")
            }
            .keyboardShortcut(key, modifiers: renameShortcut.eventModifiers)
        } else {
            Button(action: actions.renameBox) {
                Label(String(localized: "contextMenu.renameBox", defaultValue: "Rename Box…"), systemImage: "pencil")
            }
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
                snapshot.isPinned
                    ? String(localized: "contextMenu.unpinBox", defaultValue: "Unpin Box")
                    : String(localized: "contextMenu.pinBox", defaultValue: "Pin Box"),
                systemImage: snapshot.isPinned ? "pin.slash" : "pin"
            )
        }

        Divider()

        if let key = newSurfaceShortcut.keyEquivalent {
            Button(action: actions.createWindow) {
                Label(String(localized: "contextMenu.newTabInBox", defaultValue: "New Window"), systemImage: "plus.rectangle.on.rectangle")
            }
            .keyboardShortcut(key, modifiers: newSurfaceShortcut.eventModifiers)
        } else {
            Button(action: actions.createWindow) {
                Label(String(localized: "contextMenu.newTabInBox", defaultValue: "New Window"), systemImage: "plus.rectangle.on.rectangle")
            }
        }
        Button(action: actions.reconnectSSHWindowsNow) {
            Label(
                String(
                    localized: "uniconnect.reconnect.box.now",
                    defaultValue: "Reconnect SSH Windows Now"
                ),
                systemImage: "arrow.clockwise"
            )
        }
        .disabled(!snapshot.windows.contains(where: \.canReconnectSSHNow))
        Button(action: actions.updateClaude) {
            Label(
                String(localized: "contextMenu.updateClaudeInBox", defaultValue: "Update Claude in This Box…"),
                systemImage: "arrow.down.app"
            )
        }

        Divider()

        Button(action: actions.markRead) {
            Label(String(localized: "contextMenu.markBoxRead", defaultValue: "Mark Box as Read"), systemImage: "envelope.open")
        }
        .disabled(!snapshot.canMarkRead)
        Button(action: actions.markUnread) {
            Label(String(localized: "contextMenu.markBoxUnread", defaultValue: "Mark Box as Unread"), systemImage: "envelope.badge")
        }
        .disabled(!snapshot.canMarkUnread)

        Divider()

        if let key = closeShortcut.keyEquivalent {
            Button(role: .destructive, action: actions.closeBox) {
                Label(String(localized: "contextMenu.closeBox", defaultValue: "Close Box"), systemImage: "xmark.square")
            }
            .keyboardShortcut(key, modifiers: closeShortcut.eventModifiers)
        } else {
            Button(role: .destructive, action: actions.closeBox) {
                Label(String(localized: "contextMenu.closeBox", defaultValue: "Close Box"), systemImage: "xmark.square")
            }
        }
    }

    private var connectionSymbol: String {
        switch snapshot.connectionKind {
        case .local: return "terminal"
        case .ssh: return snapshot.isDisconnected ? "network.slash" : "network"
        case .mixed: return "square.stack.3d.up"
        }
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
        if let secondaryLabel = snapshot.secondaryLabel, !secondaryLabel.isEmpty {
            values.append(secondaryLabel)
        }
        values.append(String(
            format: String(localized: "uniconnect.rail.accessibility.windowCount", defaultValue: "%lld windows"),
            locale: .current,
            Int64(snapshot.windowCount)
        ))
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

    private func activateBox() {
        if snapshot.isGroup, NSEvent.modifierFlags.contains(.option), let toggleGroup = actions.toggleGroup {
            toggleGroup()
        } else {
            actions.selectBox()
        }
    }

}
