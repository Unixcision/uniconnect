import Foundation

/// One immutable row crossing the compact rail's lazy-list boundary.
struct UniConnectRailRow: Identifiable {
    enum Content {
        case chip(snapshot: UniConnectChipSnapshot, actions: UniConnectChipActions)
        case divider
    }

    let id: String
    let content: Content

    var snapshot: UniConnectChipSnapshot? {
        guard case .chip(let snapshot, _) = content else { return nil }
        return snapshot
    }
}
