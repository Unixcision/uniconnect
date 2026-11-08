import Foundation

/// What the wrapper's diary (`<dir>/<id>.log`, no secrets) says about a user switch.
///
/// The causes come from the table of `contracts/run-as-v1/LEEME.md`: the wrapper writes the
/// `UC_RUNAS_*` marks and the sudo/su messages in `LC_ALL=C`.
enum UniConnectRunAsJournal: Equatable, Sendable {
    /// Nothing decided yet.
    case running
    /// `su` is asking for its password: the diary ends in `Password: `.
    case awaitingPassword
    /// The window runs as `user`.
    case switched(user: String)
    /// The switch failed, for this cause.
    case failed(UniConnectRunAsFailure)

    /// Reads a diary's text.
    init(diary: String) {
        let lines = diary.components(separatedBy: "\n")
        if let ok = lines.first(where: { $0.hasPrefix("UC_RUNAS_OK ") }) {
            self = .switched(user: String(ok.dropFirst("UC_RUNAS_OK ".count)).trimmingCharacters(in: .whitespaces))
            return
        }
        if lines.contains(where: { $0.hasPrefix("UC_RUNAS_WRONG ") }) {
            self = .failed(.wrongUser)
            return
        }
        let lower = diary.lowercased()
        let ended = lines.contains { $0.hasPrefix("UC_RUNAS_END ") }
        if Self.passwordRefused.contains(where: { lower.contains($0) }) {
            self = ended ? .failed(.passwordIncorrect) : .running
        } else if Self.notAllowed.contains(where: { lower.contains($0) }) {
            self = ended ? .failed(.notAllowed) : .running
        } else if Self.userNotFound.contains(where: { lower.contains($0) }) {
            self = ended ? .failed(.userNotFound) : .running
        } else if ended {
            self = .failed(.failed)
        } else if diary.hasSuffix("Password: ") {
            self = .awaitingPassword
        } else {
            self = .running
        }
    }

    private static let passwordRefused = [
        "incorrect password", "sorry, try again", "no password was provided", "authentication failure",
    ]
    private static let notAllowed = ["is not in the sudoers file", "is not allowed to", "may not run sudo"]
    private static let userNotFound = ["unknown user", "does not exist"]
}
