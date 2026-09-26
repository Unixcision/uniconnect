import Foundation

/// Watches SSH windows whose automatic reconnects ran out and re-arms them when their server
/// answers again (`contracts/ssh-server-return-v1`).
///
/// Each window keeps its ``UniConnectSSHServerReturnPolicy`` between waits, so a server that
/// answers but rejects the session earns a single extra attempt, not one per round. The state is
/// forgotten when the window is stable again, reconnected by hand or closed.
@MainActor
final class UniConnectSSHServerWaiter {
    typealias Key = UniConnectSSHTargetKey

    private struct Entry {
        var policy = UniConnectSSHServerReturnPolicy()
        /// Only waiting entries are probed; a re-armed or stopped entry keeps its policy.
        var waiting = false
        var isRelevant: @MainActor () -> Bool = { false }
        var onReturn: @MainActor () -> Void = {}
    }

    private let probe: any UniConnectSSHEndpointProbing
    private let interval: Duration
    private let startsAutomatically: Bool
    private var entries: [Key: Entry] = [:]
    private var loop: Task<Void, Never>?

    /// - Parameters:
    ///   - probe: How a server's SSH port is checked.
    ///   - interval: Pause between rounds while some window is waiting (30 s in the contract).
    ///   - startsAutomatically: `false` lets tests drive ``checkWaitingServers()`` by hand.
    init(
        probe: any UniConnectSSHEndpointProbing = UniConnectTCPEndpointProbe(),
        interval: Duration = .seconds(30),
        startsAutomatically: Bool = true
    ) {
        self.probe = probe
        self.interval = interval
        self.startsAutomatically = startsAutomatically
    }

    /// Windows currently waiting for their server.
    var waitingKeys: Set<Key> {
        Set(entries.filter { $0.value.waiting }.keys)
    }

    /// Starts or resumes waiting for `key`'s server; the first check runs right away.
    /// - Parameters:
    ///   - isRelevant: Whether the window still exists and is still disconnected.
    ///   - onReturn: Re-arms the window's reconnect budget and reconnects it.
    func wait(
        for key: Key,
        isRelevant: @escaping @MainActor () -> Bool,
        onReturn: @escaping @MainActor () -> Void
    ) {
        var entry = entries[key] ?? Entry()
        entry.waiting = true
        entry.isRelevant = isRelevant
        entry.onReturn = onReturn
        entries[key] = entry
        if startsAutomatically {
            startLoopIfNeeded()
        }
    }

    /// Forgets `key` and its policy: the window is stable, was reconnected by hand, or closed.
    func forget(_ key: Key) {
        entries.removeValue(forKey: key)
    }

    /// One round: each distinct server is probed once and every waiting window gets a decision.
    func checkWaitingServers() async {
        var answersByEndpoint: [String: Bool] = [:]
        for key in Array(entries.keys) {
            guard let entry = entries[key], entry.waiting else { continue }
            guard entry.isRelevant() else {
                entries.removeValue(forKey: key)
                continue
            }
            let endpoint = "\(key.host):\(key.port)"
            let answers: Bool
            if let known = answersByEndpoint[endpoint] {
                answers = known
            } else {
                answers = await probe.answers(host: key.host, port: key.port)
                answersByEndpoint[endpoint] = answers
            }
            // The window may have been forgotten or reconnected while the probe ran.
            guard var current = entries[key], current.waiting else { continue }
            switch current.policy.observe(serverAnswers: answers) {
            case .keepWaiting:
                entries[key] = current
            case .rearm:
                current.waiting = false
                entries[key] = current
                current.onReturn()
            case .stop:
                current.waiting = false
                entries[key] = current
            }
        }
    }

    private func startLoopIfNeeded() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while let self {
                await self.checkWaitingServers()
                guard !self.waitingKeys.isEmpty else {
                    self.loop = nil
                    return
                }
                // Bounded, cancellable pause between checks: the contract's cadence, not a poll
                // for app state (the input is an external server we cannot observe otherwise).
                do {
                    try await Task.sleep(for: self.interval)
                } catch {
                    self.loop = nil
                    return
                }
            }
        }
    }
}
