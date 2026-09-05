import Foundation

struct UniConnectMobilePendingPeer: Identifiable, Equatable, Sendable {
    let address: String
    /// Untrusted display hint. Approval always identifies the observed address.
    let label: String
    let requestedAt: Date
    let expiresAt: Date
    var id: String { address }
}
