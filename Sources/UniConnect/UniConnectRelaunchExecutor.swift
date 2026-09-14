import CMUXAgentLaunch
import CmuxProcess
import Foundation

/// Closes one agent and brings the same conversation back, in its own pane.
///
/// The whole point is that it never types into a pane it has not just read. Doing this by hand to 26
/// windows, three of them were not at a prompt: one sat on a question about work in flight, one had
/// a task list where the keys went into a search box, and one came back asking whether the folder
/// was trusted with "No, exit" already selected. A blind Enter would have killed the session that
/// had just been opened.
struct UniConnectRelaunchExecutor: Sendable {
    /// One window to act on.
    struct Target: Sendable {
        let key: RelaunchTargetKey
        let label: String
        let provider: String
        let socket: String
        let session: String
        /// The argv the pane was started with, so its flags come back unchanged.
        let previousArgv: [String]
        /// Evidence gathered off the screen about which conversation lives here.
        let evidence: RelaunchIdentityEvidence?

        init(
            key: RelaunchTargetKey,
            label: String,
            provider: String,
            socket: String,
            session: String,
            previousArgv: [String],
            evidence: RelaunchIdentityEvidence? = nil
        ) {
            self.key = key
            self.label = label
            self.provider = provider
            self.socket = socket
            self.session = session
            self.previousArgv = previousArgv
            self.evidence = evidence
        }
    }

    private let driver: UniConnectRelaunchTmuxDriver
    private let dialects: RelaunchDialects
    private let sequencer = RelaunchPaneSequencer()
    /// Injected so tests do not wait for a terminal to repaint.
    private let settle: @Sendable () async -> Void

    init(
        driver: UniConnectRelaunchTmuxDriver = UniConnectRelaunchTmuxDriver(),
        dialects: RelaunchDialects = .known,
        settle: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: .seconds(1)) }
    ) {
        self.driver = driver
        self.dialects = dialects
        self.settle = settle
    }

    /// Relaunches `target`, reporting where it got to.
    func relaunch(_ target: Target) async -> RelaunchOperation.Result {
        // An agent this build does not know how to close and verify is left exactly as it is.
        guard let dialect = dialects.dialect(for: target.provider) else {
            return .init(key: target.key, state: .skipped, cause: .unsupported)
        }
        guard let pane = await driver.firstPane(socket: target.socket, session: target.session),
              let before = await driver.panePID(socket: target.socket, pane: pane) else {
            return .init(key: target.key, state: .failed, cause: .hostUnreachable)
        }

        // Identity first: nothing is closed before it is known what would have to come back.
        var conversation = target.evidence.flatMap { dialect.conversation(from: $0) }

        switch await close(target: target, pane: pane, dialect: dialect) {
        case let .failure(cause):
            return .init(key: target.key, state: cause == .folderTrust ? .needsUser : .failed, cause: cause)
        case let .success(printed):
            // What an agent prints on its way out beats anything guessed beforehand.
            conversation = printed ?? conversation
        }

        guard let conversation,
              let argv = dialect.invocation(conversation: conversation, previousArgv: target.previousArgv) else {
            // Closed but unidentifiable: say so loudly instead of resuming somebody else's.
            return .init(key: target.key, state: .needsUser, cause: .ambiguousIdentity)
        }

        await driver.type(socket: target.socket, pane: pane, text: argv.joined(separator: " "))
        for _ in 0..<30 {
            await settle()
            let screen = await driver.capture(socket: target.socket, pane: pane) ?? ""
            let reading = dialect.read(screen: screen)
            if reading == .folderTrustQuestion {
                // A permission is answered by a person. The question stays on screen.
                return .init(key: target.key, state: .needsUser, cause: .folderTrust)
            }
            guard reading == .agentReady else { continue }
            let after = await driver.panePID(socket: target.socket, pane: pane)
            let proof = RelaunchProcessProof(before: before, after: after)
            switch dialect.verify(proof: proof, reading: reading) {
            case .success:
                return .init(key: target.key, state: .verified, effectiveID: conversation)
            case let .failure(cause):
                return .init(key: target.key, state: .failed, cause: cause)
            }
        }
        return .init(key: target.key, state: .failed, cause: .unknownDialog)
    }

    /// Walks the pane out of its agent, returning the conversation it printed on the way.
    private func close(
        target: Target,
        pane: String,
        dialect: any RelaunchAgentDialect
    ) async -> Result<String?, RelaunchCause> {
        for _ in 0..<30 {
            let screen = await driver.capture(socket: target.socket, pane: pane) ?? ""
            let reading = dialect.read(screen: screen)
            if case let .exitedShowingResume(sessionID) = reading { return .success(sessionID) }
            switch sequencer.stepToClose(reading: reading) {
            case .done:
                return .success(nil)
            case let .stop(cause):
                return .failure(cause)
            case let .type(text):
                await driver.type(socket: target.socket, pane: pane, text: text)
            case .pressEnter:
                await driver.type(socket: target.socket, pane: pane, text: "")
            }
            await settle()
        }
        return .failure(.unknownDialog)
    }
}
