import Foundation

/// Saves a window the moment it is created, and again as soon as its agent's conversation is known.
///
/// Shared by every creation path (the desktop sheets and the phone): the new window reaches the
/// saved state through the same writer as «Guardar» (⌘S) right away, instead of waiting for the
/// next autosave or for someone to press ⌘S. When an agent was asked for, a probe aimed at that
/// one window runs on a short, bounded schedule until the agent has filed its conversation, and
/// the state is written again with it. Closing the window, or creating it again, cancels the wait.
@MainActor
final class UniConnectCreatedWindowPersistence {
    /// The window being followed.
    struct Owner: Hashable, Sendable {
        let workspaceID: UUID
        let panelID: UUID
    }

    /// What one targeted probe found.
    enum Capture: Equatable, Sendable {
        /// The agent's conversation is now in the window's record.
        case captured
        /// Not yet: the agent has not created its session.
        case pending
        /// The window is gone or cannot be probed; nothing more to wait for.
        case unavailable
    }

    /// Waits between probes: about 45 s in all, long enough for a slow first start, never endless.
    static let defaultProbeDelays: [Duration] = [
        .seconds(1), .seconds(2), .seconds(3), .seconds(5), .seconds(8), .seconds(12), .seconds(14),
    ]

    private let save: @MainActor () async -> Void
    private let capture: @MainActor (Owner) async -> Capture
    private let sleep: @Sendable (Duration) async throws -> Void
    private let probeDelays: [Duration]
    private var followed: [Owner: (token: UUID, task: Task<Void, Never>)] = [:]

    /// - Parameters:
    ///   - save: The «Guardar» writer, without its confirmation dialog.
    ///   - capture: Probes one window now and records what it finds.
    ///   - sleep: The bounded wait between probes; tests pass one that returns at once.
    ///   - probeDelays: The wait before each probe; its sum bounds the whole follow-up.
    init(
        save: @escaping @MainActor () async -> Void,
        capture: @escaping @MainActor (Owner) async -> Capture,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        probeDelays: [Duration] = defaultProbeDelays
    ) {
        self.save = save
        self.capture = capture
        self.sleep = sleep
        self.probeDelays = probeDelays
    }

    /// Saves now and, when `expectsAgent`, follows the window until its conversation is saved.
    ///
    /// - Returns: The follow-up, for callers that need to know when it ends.
    @discardableResult
    func windowCreated(_ owner: Owner, expectsAgent: Bool) -> Task<Void, Never> {
        followed.removeValue(forKey: owner)?.task.cancel()
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            await self?.follow(owner, expectsAgent: expectsAgent)
            if self?.followed[owner]?.token == token {
                self?.followed[owner] = nil
            }
        }
        followed[owner] = (token, task)
        return task
    }

    /// Stops following a window that was closed.
    func windowClosed(_ owner: Owner) {
        followed.removeValue(forKey: owner)?.task.cancel()
    }

    private func follow(_ owner: Owner, expectsAgent: Bool) async {
        await save()
        guard expectsAgent else { return }
        for delay in probeDelays {
            // Bounded, cancellable delay: the agent needs a moment to create its session file,
            // and the schedule above caps the whole wait.
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled else { return }
            switch await capture(owner) {
            case .captured:
                await save()
                return
            case .pending:
                continue
            case .unavailable:
                return
            }
        }
    }
}
