import Foundation

/// The host's side of a `run-as.v1` user switch, around the shared wrapper running in the pane.
///
/// Before the session starts, ``prepare(method:password:windowID:)`` leaves the password where
/// sudo's askpass reads it. After it starts, ``outcome(method:password:windowID:)`` follows the
/// wrapper's diary: it pastes the password for `su` only while `su` is the pane's question, and
/// answers with the switched user or the cause. Every wait is bounded and cancellable.
struct UniConnectRunAsSwitch: Sendable {
    private let host: any UniConnectRunAsHost
    private let sleep: @Sendable (Duration) async throws -> Void
    private let pollInterval: Duration
    private let deadline: Duration
    private let passwordWindow: Duration

    /// - Parameters:
    ///   - host: Where the window's pane runs (this Mac, or an SSH server).
    ///   - sleep: The wait between two readings of the diary; tests pass one that returns at once.
    ///   - pollInterval: How often the diary is read.
    ///   - deadline: How long the result may take (30 s in the contract).
    ///   - passwordWindow: How long `su` may take to ask (20 s in the contract).
    init(
        host: any UniConnectRunAsHost,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        pollInterval: Duration = .milliseconds(250),
        deadline: Duration = .seconds(30),
        passwordWindow: Duration = .seconds(20)
    ) {
        self.host = host
        self.sleep = sleep
        self.pollInterval = pollInterval
        self.deadline = deadline
        self.passwordWindow = passwordWindow
    }

    /// Leaves sudo's password for the wrapper, before the session is created. `su` needs nothing.
    func prepare(method: UniConnectRunAs.Method, password: String?, windowID: String) async throws {
        guard method == .sudo, let password, !password.isEmpty else { return }
        try await host.writeSecret(password, windowID: windowID)
    }

    /// Follows the switch until the wrapper decides.
    ///
    /// - Returns: `nil` when the window runs as the requested user; the cause otherwise, with the
    ///   wrapper having left the window at the connected user's shell and without an agent.
    func outcome(
        method: UniConnectRunAs.Method,
        password: String?,
        windowID: String
    ) async -> UniConnectRunAsFailure? {
        let polls = max(1, Int((deadline / pollInterval).rounded(.up)))
        let passwordPolls = Int((passwordWindow / pollInterval).rounded(.up))
        var pasted = false
        for poll in 0..<polls {
            if poll > 0 {
                do { try await sleep(pollInterval) } catch { break }
            }
            switch UniConnectRunAsJournal(diary: await host.diary(windowID: windowID) ?? "") {
            case .switched:
                return nil
            case .failed(let cause):
                await host.removeSecret(windowID: windowID)
                return cause
            case .awaitingPassword:
                // Only su's own question gets it, once, and only within its window.
                guard method == .su, !pasted, poll < passwordPolls,
                      await host.suIsAsking(windowID: windowID) else { continue }
                guard let password, !password.isEmpty else { continue }
                do {
                    try await host.pastePassword(password, windowID: windowID)
                    pasted = true
                } catch {
                    continue
                }
            case .running:
                continue
            }
        }
        await host.removeSecret(windowID: windowID)
        return .timeout
    }
}
