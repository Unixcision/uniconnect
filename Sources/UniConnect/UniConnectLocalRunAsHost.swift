import CmuxProcess
import Foundation

/// `run-as.v1` on this Mac: the wrapper's secret and diary under this user's home, and the
/// window's pane on its own tmux server.
///
/// The password goes into 0600 files only (sudo's secret, and the buffer file `su`'s paste is
/// loaded from, removed at once), never into a command line: the commands carry file paths and
/// pane names.
struct UniConnectLocalRunAsHost: UniConnectRunAsHost {
    private let directory: URL
    private let binding: UniConnectLocalTmuxBinding
    private let runner: any CommandRunning

    /// - Parameters:
    ///   - binding: The window's tmux session.
    ///   - homeDirectory: This user's home; the wrapper uses `$HOME/.local/state/uniconnect/runas`.
    ///   - runner: Runs tmux and pgrep; tests pass a fake.
    init(
        binding: UniConnectLocalTmuxBinding,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        runner: any CommandRunning = CommandRunner()
    ) {
        self.binding = binding
        self.directory = homeDirectory.appendingPathComponent(".local/state/uniconnect/runas", isDirectory: true)
        self.runner = runner
    }

    func writeSecret(_ password: String, windowID: String) async throws {
        try Self.writeSecretNow(password, windowID: windowID, directory: directory)
    }

    /// Writes sudo's secret synchronously, so it exists before the window's pane can start.
    static func writeSecretNow(
        _ password: String,
        windowID: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        try writeSecretNow(
            password, windowID: windowID,
            directory: homeDirectory.appendingPathComponent(".local/state/uniconnect/runas", isDirectory: true)
        )
    }

    private static func writeSecretNow(_ password: String, windowID: String, directory: URL) throws {
        try UniConnectAtomicFileWriter.write(
            Data(password.utf8), to: directory.appendingPathComponent("\(windowID).secret", isDirectory: false),
            filePermissions: 0o600, directoryPermissions: 0o700
        )
    }

    func removeSecret(windowID: String) async {
        try? UniConnectAtomicFileWriter.removeIfPresent(at: file(windowID, "secret"))
    }

    func diary(windowID: String) async -> String? {
        try? String(contentsOf: file(windowID, "log"), encoding: .utf8)
    }

    func suIsAsking(windowID: String) async -> Bool {
        guard let rawPID = await tmux(["display-message", "-p", "-t", "=\(binding.name):", "#{pane_pid}"]),
              let panePID = Int(rawPID.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        let children = await runner.runStandardOutput(
            directory: "/", executable: "/usr/bin/pgrep", arguments: ["-P", String(panePID), "-x", "su"], timeout: 5
        )
        return !(children ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func pastePassword(_ password: String, windowID: String) async throws {
        let buffer = "uc-rs-\(windowID)"
        let source = file(windowID, "paste")
        try UniConnectAtomicFileWriter.write(
            Data(password.utf8), to: source, filePermissions: 0o600, directoryPermissions: 0o700
        )
        let loaded = await tmux(["load-buffer", "-b", buffer, source.path])
        try? UniConnectAtomicFileWriter.removeIfPresent(at: source)
        guard loaded != nil,
              await tmux(["paste-buffer", "-d", "-b", buffer, "-t", "=\(binding.name):"]) != nil,
              await tmux(["send-keys", "-t", "=\(binding.name):", "Enter"]) != nil else {
            _ = await tmux(["delete-buffer", "-b", buffer])
            throw UniConnectRunAsFailure.failed
        }
    }

    private func file(_ windowID: String, _ suffix: String) -> URL {
        directory.appendingPathComponent("\(windowID).\(suffix)", isDirectory: false)
    }

    private func tmux(_ arguments: [String]) async -> String? {
        await runner.runStandardOutput(
            directory: "/", executable: "tmux", arguments: ["-L", binding.socketName] + arguments, timeout: 5
        )
    }
}
