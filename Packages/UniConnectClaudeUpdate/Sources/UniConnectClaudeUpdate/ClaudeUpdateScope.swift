/// The set of visible Claude targets selected for one update operation.
public enum ClaudeUpdateScope: Sendable, Hashable, Codable {
    /// Update exactly one selected target.
    case selected(ClaudeUpdateTargetID)

    /// Update every visible Claude target in the identified UniConnect box.
    case box(id: String)

    /// Update every visible Claude target currently open in UniConnect.
    case allOpen
}
