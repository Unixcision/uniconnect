/// Resolves an application selection into immutable, currently visible Claude targets.
public protocol ClaudeUpdateTargetProviding: Sendable {
    /// Resolves targets without mutating terminals or remote sessions.
    ///
    /// - Parameter scope: The user-selected update scope.
    /// - Returns: Targets in deterministic visible order, including unresolved targets to skip.
    /// - Throws: A provider-specific discovery error before any update operation starts.
    func targets(for scope: ClaudeUpdateScope) async throws -> [ClaudeUpdateTarget]
}
