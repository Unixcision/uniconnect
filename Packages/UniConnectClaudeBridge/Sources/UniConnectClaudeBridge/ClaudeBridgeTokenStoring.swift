import Foundation

/// Persists per-route HMAC tokens in an encrypted application-owned vault.
public protocol ClaudeBridgeTokenStoring: Sendable {
    /// Loads the token previously enrolled for a route.
    ///
    /// - Parameter routeID: Stable bridge route UUID.
    /// - Returns: A 32-byte token, or `nil` before first enrollment.
    /// - Throws: A repository error when encrypted storage cannot be read.
    func token(for routeID: UUID) async throws -> Data?

    /// Persists an enrolled token and its cleanup grouping identity.
    ///
    /// - Parameters:
    ///   - token: Exactly 32 random bytes generated on the remote host.
    ///   - routeID: Stable bridge route UUID.
    ///   - credentialID: Vault credential UUID used for grouped cleanup.
    /// - Throws: A repository error when encrypted storage cannot be written.
    func store(token: Data, for routeID: UUID, credentialID: UUID) async throws

    /// Removes a single route token.
    ///
    /// - Parameter routeID: Stable bridge route UUID.
    /// - Throws: A repository error when encrypted storage cannot be written.
    func removeToken(for routeID: UUID) async throws

    /// Lists route identities associated with one SSH credential.
    ///
    /// - Parameter credentialID: Encrypted-vault credential UUID.
    /// - Returns: The stable route UUIDs owned by the credential.
    /// - Throws: A repository error when encrypted storage cannot be read.
    func routeIDs(for credentialID: UUID) async throws -> [UUID]
}
