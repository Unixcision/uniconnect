/// The targets sharing one host-level Claude update command.
public struct ClaudeUpdateHostPlan: Sendable, Hashable, Codable, Identifiable {
    /// The host identity and stable group identifier.
    public let host: ClaudeUpdateHostIdentity

    /// Targets on this host in deterministic discovery order.
    public let targets: [ClaudeUpdateTarget]

    /// The common installation identity, or `nil` when every target is unresolved.
    public let installationID: String?

    /// The common executable path, or `nil` when every target is unresolved.
    public let executablePath: String?

    /// The stable host identity used by collection views.
    public var id: ClaudeUpdateHostIdentity { host }

    /// Creates a validated host group.
    ///
    /// Callers normally receive host groups from ``ClaudeUpdatePlan`` rather than constructing
    /// them directly.
    ///
    /// - Parameters:
    ///   - host: The host whose binary is updated once.
    ///   - targets: The visible targets sharing that host.
    ///   - installationID: Their common resolved installation identity.
    ///   - executablePath: Their common resolved executable path.
    public init(
        host: ClaudeUpdateHostIdentity,
        targets: [ClaudeUpdateTarget],
        installationID: String?,
        executablePath: String?
    ) {
        self.host = host
        self.targets = targets
        self.installationID = installationID
        self.executablePath = executablePath
    }
}
