import Foundation

/// Secret-free identity of the remote tmux target owned by one UniConnect window.
///
/// Credential revisions, passwords, identity files, and jump routes are deliberately
/// excluded: two credentials that ultimately name the same user/host/port/session must
/// not create two silent clients for that target.
struct UniConnectSSHTargetKey: Hashable, Sendable {
    let username: String?
    let host: String
    let port: Int
    let tmuxSession: String

    init?(session: DetectedSSHSession, tmuxSession: String) {
        self.init(
            destination: session.destination,
            port: session.port,
            tmuxSession: tmuxSession
        )
    }

    init?(destination: String, port: Int?, tmuxSession: String) {
        let destination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let tmuxSession = tmuxSession.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty,
              !tmuxSession.isEmpty else {
            return nil
        }

        let split = Self.splitDestination(destination)
        var host = split.host.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("[") && host.hasSuffix("]") && host.count > 2 {
            host.removeFirst()
            host.removeLast()
        }
        while host.count > 1 && host.hasSuffix(".") {
            host.removeLast()
        }
        guard !host.isEmpty else { return nil }

        let resolvedPort = port ?? 22
        guard (1...65_535).contains(resolvedPort) else { return nil }

        let username = split.username?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.username = username?.isEmpty == false ? username : nil
        self.host = host.lowercased()
        self.port = resolvedPort
        self.tmuxSession = tmuxSession
    }

    private static func splitDestination(_ destination: String) -> (username: String?, host: String) {
        guard let separator = destination.lastIndex(of: "@") else {
            return (nil, destination)
        }
        return (
            String(destination[..<separator]),
            String(destination[destination.index(after: separator)...])
        )
    }
}
