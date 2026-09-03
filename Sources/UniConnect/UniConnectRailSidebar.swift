import SwiftUI
import AppKit
import Foundation

// MARK: - Compact "rail" sidebar
//
// UniConnect's collapsed presentation of the workspace sidebar: one coloured tile per
// box, stacked vertically, with the selected one ringed in the coral accent. It is a
// deliberately small, read-mostly view: it only observes `TabManager` (order, groups,
// selection) and each tile observes its own `Workspace` for name/colour changes.
// Everything heavier (drag & drop, context menus, notifications preview) stays in
// `VerticalTabsSidebar`; expanding the rail brings it all back.

struct UniConnectRailSidebar: View {
    /// UserDefaults key of the persisted compact/expanded choice.
    static let compactDefaultsKey = "uniconnect.sidebarCompact"
    /// Fixed width of the rail (the sidebar resizer is disabled while compact).
    static let width: CGFloat = 64
    static let tileSize: CGFloat = 34
    static let tileCornerRadius: CGFloat = 11
    static let tileSpacing: CGFloat = 8

    @EnvironmentObject private var tabManager: TabManager
    @EnvironmentObject private var notificationStore: TerminalNotificationStore
    @Environment(\.colorScheme) private var colorScheme

    /// Same action as the "+" of the expanded sidebar.
    let onNewTab: () -> Void
    /// Switches back to the full sidebar.
    let onExpand: () -> Void

    private enum Row: Identifiable {
        case workspace(Workspace)
        case divider(afterWorkspaceId: UUID)

        var id: String {
            switch self {
            case .workspace(let workspace): return "ws-\(workspace.id.uuidString)"
            case .divider(let afterWorkspaceId): return "div-\(afterWorkspaceId.uuidString)"
            }
        }
    }

    /// Workspaces in sidebar order with a thin divider wherever the group changes
    /// (grouped boxes stay contiguous in `tabManager.tabs`, so this is enough).
    private var rows: [Row] {
        var result: [Row] = []
        var previous: Workspace?
        for workspace in tabManager.tabs {
            if let previous, previous.groupId != workspace.groupId {
                result.append(.divider(afterWorkspaceId: previous.id))
            }
            result.append(.workspace(workspace))
            previous = workspace
        }
        return result
    }

    var body: some View {
        let selectedId = tabManager.selectedTabId
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: Self.tileSpacing) {
                    ForEach(rows) { row in
                        switch row {
                        case .workspace(let workspace):
                            UniConnectRailTile(
                                workspace: workspace,
                                isSelected: workspace.id == selectedId,
                                unreadCount: notificationStore.unreadCount(forTabId: workspace.id),
                                onSelect: { tabManager.selectWorkspace(workspace) }
                            )
                        case .divider:
                            Rectangle()
                                .fill(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.12))
                                .frame(width: Self.tileSize - 6, height: 1)
                                .padding(.vertical, 2)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, SidebarWorkspaceListMetrics.firstRowTopOffset)
                .padding(.bottom, 12)
            }

            footer
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .accessibilityIdentifier("UniConnectRailSidebar")
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Button(action: onNewTab) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: Self.tileSize, height: Self.tileSize)
                    .background(
                        RoundedRectangle(cornerRadius: Self.tileCornerRadius, style: .continuous)
                            .strokeBorder(
                                Color.primary.opacity(colorScheme == .dark ? 0.22 : 0.16),
                                style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: Self.tileCornerRadius, style: .continuous))
            }
            .buttonStyle(UniConnectRailButtonStyle())
            .safeHelp("Nueva caja")
            .accessibilityLabel("Nueva caja")
            .accessibilityIdentifier("UniConnectRailNewWorkspace")

            Button(action: onExpand) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(UniConnectRailButtonStyle())
            .safeHelp("Expandir barra lateral (⌘⌥B)")
            .accessibilityLabel("Expandir barra lateral")
            .accessibilityIdentifier("UniConnectRailExpand")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }
}

// MARK: - Tile

private struct UniConnectRailTile: View {
    @ObservedObject var workspace: Workspace
    let isSelected: Bool
    let unreadCount: Int
    let onSelect: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    private var displayName: String {
        let custom = workspace.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !custom.isEmpty { return custom }
        let title = workspace.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Caja" : title
    }

    private var initial: String {
        guard let first = displayName.first else { return "•" }
        return String(first).uppercased()
    }

    /// Box colour, brightened for dark appearances like the expanded rows do; neutral
    /// gray when the box has no colour.
    private var tileNSColor: NSColor {
        if let hex = workspace.customColor, !hex.isEmpty,
           let color = WorkspaceTabColorSettings.displayNSColor(hex: hex, colorScheme: colorScheme) {
            return color
        }
        return colorScheme == .dark
            ? NSColor(srgbRed: 0.42, green: 0.44, blue: 0.48, alpha: 1)
            : NSColor(srgbRed: 0.62, green: 0.64, blue: 0.68, alpha: 1)
    }

    private var glyphColor: Color {
        Color(nsColor: cmuxReadableForegroundNSColor(on: tileNSColor, opacity: 0.95))
    }

    private var kindSymbol: String? {
        guard let profile = workspace.uniConnectProfile else { return nil }
        return profile.isSSH ? "network" : "terminal"
    }

    private var tooltip: String {
        guard let profile = workspace.uniConnectProfile else { return displayName }
        if profile.isSSH, let host = profile.hostLabel, !host.isEmpty {
            return "\(displayName) — \(host)"
        }
        return profile.isSSH ? "\(displayName) — SSH" : "\(displayName) — Local"
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: UniConnectRailSidebar.tileCornerRadius, style: .continuous)
        Button(action: onSelect) {
            ZStack {
                shape
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(nsColor: tileNSColor).opacity(isSelected || isHovered ? 1 : 0.88),
                                Color(nsColor: tileNSColor).opacity(isSelected || isHovered ? 0.86 : 0.72)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                shape
                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.18), lineWidth: 1)
                Text(initial)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(glyphColor)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
            .frame(width: UniConnectRailSidebar.tileSize, height: UniConnectRailSidebar.tileSize)
            .overlay(alignment: .bottomTrailing) {
                if let kindSymbol {
                    Image(systemName: kindSymbol)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(Color.black.opacity(0.62)))
                        .offset(x: 4, y: 4)
                }
            }
            .overlay(alignment: .topTrailing) {
                if unreadCount > 0 {
                    Circle()
                        .fill(cmuxAccentColor())
                        .frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5))
                        .offset(x: 3, y: -3)
                }
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: UniConnectRailSidebar.tileCornerRadius + 3, style: .continuous)
                        .strokeBorder(cmuxAccentColor(), lineWidth: 2)
                        .padding(-4)
                }
            }
            .scaleEffect(isHovered && !isSelected ? 1.06 : 1)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.16), value: isSelected)
            .contentShape(Rectangle())
        }
        .buttonStyle(UniConnectRailButtonStyle())
        .onHover { isHovered = $0 }
        .safeHelp(tooltip)
        .accessibilityLabel(tooltip)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier("UniConnectRailTile-\(workspace.id.uuidString)")
    }
}

// MARK: - Button style

private struct UniConnectRailButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
