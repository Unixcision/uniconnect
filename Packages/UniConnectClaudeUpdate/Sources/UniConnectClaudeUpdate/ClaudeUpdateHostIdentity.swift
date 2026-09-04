/// A stable, credential-free identity for one local machine or remote endpoint.
public struct ClaudeUpdateHostIdentity: Sendable, Codable {
    /// The host location.
    public let kind: ClaudeUpdateHostKind

    /// A stable application-owned identity for the local host or remote endpoint and credential.
    public let id: String

    /// A presentation-only host name that must not contain credential material.
    public let displayName: String

    /// Creates a host identity.
    ///
    /// Remote identifiers must incorporate both the normalized endpoint and credential-record ID,
    /// but never a username, password, token, raw SSH command, or environment value. Installation
    /// identity is modeled separately by ``ClaudeUpdateHostPlanID``.
    ///
    /// - Parameters:
    ///   - kind: Whether this is the local Mac or a remote host.
    ///   - id: A stable, non-secret identity used for equality and grouping.
    ///   - displayName: A non-secret name suitable for presentation.
    public init(kind: ClaudeUpdateHostKind, id: String, displayName: String) {
        self.kind = kind
        self.id = id
        self.displayName = displayName
    }
}

extension ClaudeUpdateHostIdentity: Hashable {
    /// Compares stable host identity without treating a renamed display label as a new host.
    ///
    /// - Parameters:
    ///   - lhs: The first host identity.
    ///   - rhs: The second host identity.
    /// - Returns: `true` when both values identify the same host location.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.id == rhs.id
    }

    /// Hashes the stable host identity used for grouping.
    ///
    /// - Parameter hasher: The hasher receiving the host kind and stable ID.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(id)
    }
}
