import Foundation
@testable import UniConnectClaudeBridge

actor BridgeTestTokenStore: ClaudeBridgeTokenStoring {
    private struct Entry {
        let token: Data
        let credentialID: UUID
    }

    private var entries: [UUID: Entry] = [:]

    func token(for routeID: UUID) async throws -> Data? {
        entries[routeID]?.token
    }

    func store(token: Data, for routeID: UUID, credentialID: UUID) async throws {
        entries[routeID] = Entry(token: token, credentialID: credentialID)
    }

    func removeToken(for routeID: UUID) async throws {
        entries.removeValue(forKey: routeID)
    }

    func routeIDs(for credentialID: UUID) async throws -> [UUID] {
        entries.compactMap { $0.value.credentialID == credentialID ? $0.key : nil }
    }
}
