import CmuxProcess
import Darwin
import Foundation

/// Keeps the local tmux server of UniConnect outside the app's process coalition.
///
/// On macOS 27 a Force Quit of an app (from the Dock, or ⌥⌘⎋) sends SIGTERM to every process of
/// its coalition, and a tmux server started from one of the app's terminals belongs to it. On
/// 8-nov-2026 a Force Quit took the server down, and with it the 32 AIs that lived in it. A
/// server that launchd starts lives in a coalition of its own.
///
/// This installs a per-user launch agent that runs the server in the foreground (`tmux -D`,
/// which also keeps it alive with no sessions). The windows' launch plan asks launchd to start it
/// with `launchctl kickstart` when no server answers, and starts one itself only when the agent
/// is not there. Nothing here stops, reloads or replaces a running server: a server that is
/// already up keeps running where it was born until it ends on its own.
actor UniConnectLocalTmuxServerAgent {
    /// What installing the agent found.
    enum Outcome: Equatable, Sendable {
        /// The agent is loaded in launchd and will start the server on demand.
        case ready
        /// No tmux executable: windows fall back to their recovery shell anyway.
        case tmuxMissing
        /// launchd refused it; windows keep starting the server themselves.
        case failed(String)
    }

    /// The launchd label of the agent that serves [socketName].
    static func label(socketName: String) -> String {
        "com.unixcision.uniconnect.tmux." + socketName
    }

    private let socketName: String
    private let launchAgentsDirectory: URL
    private let userID: uid_t
    private let tmuxCandidates: [String]
    private let language: String
    private let commands: any CommandRunning
    // FileManager is documented thread-safe for the calls made here.
    private nonisolated(unsafe) let fileManager: FileManager

    /// - Parameters:
    ///   - socketName: the `-L` socket the app's windows use.
    ///   - homeDirectory: where `Library/LaunchAgents` lives; tests pass a temporary folder.
    ///   - userID: the GUI domain the agent is loaded in (`gui/<uid>`).
    ///   - tmuxCandidates: executables tried in order; the first one that exists runs the server.
    ///   - language: `LANG` for the server and the panes it starts, which launchd would leave unset.
    ///   - commands: runs `launchctl`; tests inject a fake.
    init(
        socketName: String,
        homeDirectory: URL,
        userID: uid_t = getuid(),
        tmuxCandidates: [String] = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"],
        language: String? = ProcessInfo.processInfo.environment["LANG"],
        commands: any CommandRunning = CommandRunner(),
        fileManager: FileManager = .default
    ) {
        self.socketName = socketName
        self.launchAgentsDirectory = homeDirectory.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        self.userID = userID
        self.tmuxCandidates = tmuxCandidates
        self.language = language.flatMap { $0.isEmpty ? nil : $0 } ?? "es_ES.UTF-8"
        self.commands = commands
        self.fileManager = fileManager
    }

    nonisolated var label: String { Self.label(socketName: socketName) }

    nonisolated var plistURL: URL { launchAgentsDirectory.appendingPathComponent(label + ".plist") }

    private nonisolated var serviceTarget: String { "gui/\(userID)/\(label)" }

    /// Writes the agent's plist when it changed and loads it in launchd when it is not loaded.
    ///
    /// A loaded agent whose server is running is never unloaded, even with a changed plist:
    /// unloading it would end the server and every AI in it. The new plist takes effect the next
    /// time the agent is loaded.
    func install() async -> Outcome {
        guard let tmux = tmuxCandidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) else {
            return .tmuxMissing
        }
        let changed: Bool
        do {
            changed = try writePlist(tmuxExecutable: tmux)
        } catch {
            return .failed("plist: \(error.localizedDescription)")
        }
        let status = await commands.run(
            directory: "/", executable: "/bin/launchctl", arguments: ["print", serviceTarget], timeout: 5
        )
        if status.exitStatus == 0, status.executionError == nil {
            // Loaded. Reload only an idle agent whose definition changed.
            guard changed, status.stdout?.contains("state = running") != true else { return .ready }
            _ = await commands.run(
                directory: "/", executable: "/bin/launchctl", arguments: ["bootout", serviceTarget], timeout: 10
            )
        }
        let bootstrap = await commands.run(
            directory: "/", executable: "/bin/launchctl",
            arguments: ["bootstrap", "gui/\(userID)", plistURL.path], timeout: 10
        )
        guard bootstrap.exitStatus == 0, bootstrap.executionError == nil, !bootstrap.timedOut else {
            return .failed((bootstrap.stderr ?? bootstrap.executionError ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return .ready
    }

    /// The agent's definition: the server in the foreground on the app's socket, started only
    /// on demand, never restarted by launchd behind the app's back.
    nonisolated func plist(tmuxExecutable: String) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [tmuxExecutable, "-D", "-f", "/dev/null", "-L", socketName],
            "EnvironmentVariables": [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                "LANG": language,
            ],
            // Panes run interactive AIs: no background throttling of CPU or I/O.
            "ProcessType": "Interactive",
            "RunAtLoad": false,
            // When the server ends, launchd must not signal the panes it leaves behind.
            "AbandonProcessGroup": true,
        ]
    }

    /// Writes the plist atomically when its bytes differ; returns whether it did.
    private func writePlist(tmuxExecutable: String) throws -> Bool {
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist(tmuxExecutable: tmuxExecutable), format: .xml, options: 0
        )
        if let current = fileManager.contents(atPath: plistURL.path), current == data { return false }
        try fileManager.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)
        return true
    }
}
