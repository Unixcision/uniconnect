/// The host-level result proven by command status, output, and before/after versions.
public enum ClaudeBinaryUpdateStatus: String, Sendable, Hashable, Codable {
    /// The installed version increased.
    case updated

    /// The version stayed equal and the output explicitly reported it current.
    case alreadyUpdated

    /// The available evidence did not prove either safe success state.
    case failed
}
