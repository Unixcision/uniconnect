import CMUXAgentLaunch
import Foundation

/// Saves an agent's monitors and background shells before it is closed, so it can relaunch them.
///
/// `~/.local/state/uniconnect/relaunch-v1/monitores/<conversación>-<AAAAMMDD-HHMMSS>.txt`, in the
/// format Mac and Linux share (`contracts/relaunch-v1/LEEME.md`, «Monitores y shells de fondo»):
///
/// ```text
/// # sesion=uc-prueba conversacion=57c8… estado=shell fecha=2026-11-10T00:17:55Z
/// # Monitor o shell de fondo 1
/// tail -n0 -F /tmp/uc-prueba.log | grep --line-buffered HOLA
/// # (copia de /tmp/claude-501/x/scratchpad/w.sh en /Users/d/.local/state/…/57c8…-20261110-001755/)
/// ```
///
/// The copies of the `/tmp/claude-<uid>/…` files the commands mention go in a folder of the same
/// name: the scratchpad may not survive the restart.
struct UniConnectRelaunchMonitorArchive: Sendable {
    /// One shell to save.
    struct Entry: Sendable, Equatable {
        let shell: ClaudeBackgroundShell
        let pid: Int32
        let workingDirectory: String?
    }

    /// The `monitores` folder.
    let root: URL
    /// Copies larger than this are skipped; the command still names the original path.
    private let maximumCopyBytes = 4 * 1_024 * 1_024

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/state/uniconnect/relaunch-v1/monitores", isDirectory: true)) {
        self.root = root
    }

    /// Writes the file for `sessionID`.
    ///
    /// - Parameters:
    ///   - entries: The shells, in the order they were found.
    ///   - sessionID: The conversation they belong to, which names the file.
    ///   - tmuxSession: The tmux session of its window.
    ///   - status: The agent's status when it was closed (`idle`, `busy`, `shell`…).
    ///   - now: When they were saved.
    /// - Returns: The saved file.
    /// - Throws: When the folder or the file cannot be written; then nothing is closed.
    func save(_ entries: [Entry], sessionID: String, tmuxSession: String, status: String, now: Date) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: now)
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = root.appendingPathComponent("\(sessionID)-\(stamp).txt", isDirectory: false)
        let copies = root.appendingPathComponent("\(sessionID)-\(stamp)", isDirectory: true)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = .current
        var text = "# sesion=\(tmuxSession) conversacion=\(sessionID) estado=\(status) fecha=\(iso.string(from: now))\n"
        for (index, entry) in entries.enumerated() {
            text += "# Monitor o shell de fondo \(index + 1)\n\(entry.shell.command)\n"
            for path in entry.shell.referencedFiles where copyIfSmall(path, into: copies) != nil {
                text += "# (copia de \(path) en \(copies.path)/)\n"
            }
            text += "\n"
        }
        try Data(text.utf8).write(to: file, options: .atomic)
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }

    private func copyIfSmall(_ path: String, into folder: URL) -> URL? {
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= maximumCopyBytes else { return nil }
        let destination = folder.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)
        do {
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
            try manager.copyItem(atPath: path, toPath: destination.path)
            return destination
        } catch {
            return nil
        }
    }
}
