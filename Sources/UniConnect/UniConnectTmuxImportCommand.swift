import Foundation

/// Builds the remote tmux command allowed by an import declaration.
enum UniConnectTmuxImportCommand {
    static func launch(session: String, policy: UniConnectTmuxImportPolicy) -> String? {
        guard isValidSession(session) else { return nil }
        let quoted = shellQuote(session)
        switch policy {
        case .attachExisting, .unspecified:
            return "tmux attach-session -t \(quoted)"
        case .createIfMissing:
            return "tmux new-session -A -s \(quoted)"
        }
    }

    static func readOnlyExistenceCheck(session: String) -> String? {
        guard isValidSession(session) else { return nil }
        return "tmux has-session -t \(shellQuote(session))"
    }

    private static func isValidSession(_ value: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        return !value.isEmpty && value.count <= 40 && value.allSatisfy(allowed.contains)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
