import Foundation
import UniConnectClaudeBridge

/// An immutable rendering snapshot for one box or group in UniConnect's compact rail.
struct UniConnectChipSnapshot: Identifiable, Equatable, Sendable {
    enum ConnectionKind: String, Equatable, Sendable {
        case local
        case ssh
        case mixed
    }

    let id: UUID
    let workspaceID: UUID
    let groupID: UUID?
    let isGroupCollapsed: Bool
    let displayName: String
    let secondaryLabel: String?
    let symbolName: String?
    let monogram: String
    let colorHex: String
    let connectionKind: ConnectionKind
    let isDisconnected: Bool
    let isConnecting: Bool
    let isSelected: Bool
    let isPinned: Bool
    let unreadCount: Int
    let bridgeStatus: ClaudeBridgeStatus?
    let windows: [UniConnectWindowSnapshot]
    let shortcutDigit: Int?

    var isGroup: Bool { groupID != nil }
    var windowCount: Int { windows.count }
    var canMarkRead: Bool { unreadCount > 0 }
    var canMarkUnread: Bool { unreadCount == 0 }
    var requiresLocalRootReassignment: Bool {
        windows.contains(where: \.requiresLocalRootReassignment)
    }

    /// Produces a stable two-character fallback for dense rails.
    static func monogram(for name: String) -> String {
        let normalized = name
            .replacingOccurrences(
                of: "([a-z0-9])([A-Z])",
                with: "$1 $2",
                options: .regularExpression
            )
            .replacingOccurrences(of: "[-_./]+", with: " ", options: .regularExpression)
        let tokens = normalized
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }

        if tokens.count >= 2 {
            return tokens.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        }

        let compact = (tokens.first ?? name)
            .filter { $0.isLetter || $0.isNumber }
        let prefix = String(compact.prefix(2)).uppercased()
        return prefix.isEmpty ? "\u{2022}" : prefix
    }

    /// Returns a deterministic, high-contrast rail colour when no custom colour exists.
    static func fallbackColorHex(for id: UUID) -> String {
        let palette = [
            "#3769B4", "#B3366A", "#C54A3C", "#A8B747",
            "#C53A68", "#55A84E", "#4899AA", "#852FB1",
            "#4857B8", "#83AB48", "#D15B31", "#2DA08F",
        ]
        var uuid = id.uuid
        let bytes = withUnsafeBytes(of: &uuid) { Array($0) }
        let stableIndex = bytes.enumerated().reduce(0) { partial, pair in
            (partial &* 31 &+ Int(pair.element) &+ pair.offset) % palette.count
        }
        return palette[stableIndex]
    }
}
