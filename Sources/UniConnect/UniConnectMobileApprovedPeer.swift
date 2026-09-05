import Foundation

struct UniConnectMobileApprovedPeer: Codable, Identifiable, Equatable, Sendable {
    let address: String
    let label: String
    let approvedAt: Date
    var id: String { address }
}
