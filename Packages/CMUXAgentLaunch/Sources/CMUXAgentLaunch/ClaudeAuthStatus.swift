import Foundation

/// Whether Claude is logged in on an installation, from `claude auth status` (JSON output).
///
/// Checked before anything of that installation is closed: a Claude reopened without a login is a
/// window that can do nothing until somebody runs `/login` (IBERIAVO-DESA, 09-11-2026).
public struct ClaudeAuthStatus: Sendable, Equatable {
    /// The value of `loggedIn`.
    public let loggedIn: Bool

    /// Parses the command's output.
    ///
    /// - Parameter output: What `claude auth status` printed; leading noise before the JSON object
    ///   (a login shell's banner) is skipped.
    /// - Returns: `nil` when no object with a boolean `loggedIn` is found, which is not a login.
    public init?(output: String) {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(output[start...end].utf8)) as? [String: Any],
              let loggedIn = object["loggedIn"] as? Bool else { return nil }
        self.loggedIn = loggedIn
    }
}
