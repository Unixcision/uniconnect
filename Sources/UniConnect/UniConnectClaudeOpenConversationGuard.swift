import CMUXAgentLaunch
import Foundation

/// Tells whether a Claude conversation is already open in a live process on this Mac.
///
/// Resuming a conversation that another window (or another terminal) still has open duplicates
/// it: two Claude processes writing one transcript. Before any automatic resume the local session
/// files are checked; a live holder means the window opens as a shell and the conversation stays
/// as its latest one, to be resumed by hand. Only Claude publishes such files; for every other
/// provider the guard answers "not open" and the claim registry is the only protection.
struct UniConnectClaudeOpenConversationGuard: Sendable {
    private let directory: AgentClaudeSessionDirectory

    /// Creates the guard over one Claude configuration folder.
    ///
    /// - Parameter configDirectory: `~/.claude` by default; tests pass a temporary folder.
    init(
        configDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".claude", isDirectory: true)
    ) {
        directory = AgentClaudeSessionDirectory(root: configDirectory) { pid in
            // A session file only counts while its pid is alive and is still Claude.
            guard let live = CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: pid) else { return false }
            let sample = AgentProcessSample(pid: pid, parentPID: 0, userID: -1, arguments: live.arguments)
            return AgentObservedProvider.classify(sample, hasClaudeSession: true) == .claude
        }
    }

    /// Creates the guard over an explicit session directory, for tests.
    init(directory: AgentClaudeSessionDirectory) {
        self.directory = directory
    }

    /// Whether `snapshot` is a Claude conversation some live process has open right now.
    func isOpenElsewhere(_ snapshot: SessionRestorableAgentSnapshot?) -> Bool {
        guard let snapshot, snapshot.kind == .claude else { return false }
        return !directory.liveHolders(sessionID: snapshot.sessionId).isEmpty
    }
}
