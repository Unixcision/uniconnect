import Foundation

protocol UniConnectMobileAccessRepository: Sendable {
    func load() async throws -> [UniConnectMobileApprovedPeer]
    func save(_ peers: [UniConnectMobileApprovedPeer]) async throws
}
