import Foundation
@testable import UniConnectClaudeBridge

actor BridgeTestTokenStore: ClaudeBridgeTokenStoring {
    private struct Entry {
        let token: Data
        let credentialID: UUID
    }

    private var entries: [UUID: Entry] = [:]
    private var storeSuspension: BridgeTestSleeper?
    private var failSuspendedStore = false

    func token(for routeID: UUID, credentialID: UUID) async throws -> Data? {
        guard let entry = entries[routeID], entry.credentialID == credentialID else {
            return nil
        }
        return entry.token
    }

    func store(token: Data, for routeID: UUID, credentialID: UUID) async throws {
        if let suspension = storeSuspension {
            storeSuspension = nil
            try await suspension.sleep(for: .zero)
            if failSuspendedStore {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        entries[routeID] = Entry(token: token, credentialID: credentialID)
    }

    func suspendNextStore(using suspension: BridgeTestSleeper, thenFail: Bool) {
        storeSuspension = suspension
        failSuspendedStore = thenFail
    }

    func removeToken(for routeID: UUID) async throws {
        entries.removeValue(forKey: routeID)
    }

    func routeIDs(for credentialID: UUID) async throws -> [UUID] {
        entries.compactMap { $0.value.credentialID == credentialID ? $0.key : nil }
    }
}
