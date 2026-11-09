import Foundation

/// What `claude update` did on one installation, reported once in `updates[]`.
///
/// One installation is one destination machine, user and launcher: the update runs once for all
/// of its windows, before any of them is closed.
public struct RelaunchInstallationUpdate: Sendable, Equatable {
    /// How the update ended.
    public enum State: String, Sendable, Codable {
        /// A newer version was installed.
        case updated = "actualizado"
        /// The installed version was already the latest.
        case alreadyCurrent = "ya_al_dia"
        /// The update did not work; that installation's windows are left as they were.
        case failed = "fallida"
    }

    /// The installation's host as it appears in target keys (`local:<mac>`, `ssh:user@host:port`).
    public let host: String
    /// How the update ended.
    public let state: State
    /// The version before the update, when it could be read.
    public let from: String?
    /// The version after the update, when it could be read.
    public let to: String?

    /// Creates the outcome of one installation's update.
    ///
    /// - Parameters:
    ///   - host: The installation's host, as in target keys.
    ///   - state: How the update ended.
    ///   - from: The version before.
    ///   - to: The version after.
    public init(host: String, state: State, from: String?, to: String?) {
        self.host = host
        self.state = state
        self.from = from
        self.to = to
    }

    /// The entry as it travels in an `apply`/`status` response.
    public var json: [String: Any] {
        var fields: [String: Any] = ["host": host, "state": state.rawValue]
        if let from { fields["from"] = from }
        if let to { fields["to"] = to }
        return fields
    }
}
