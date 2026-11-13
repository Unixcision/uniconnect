import Foundation

/// Coalesces durable mutations with a bounded delay, preserving a trailing save of the latest state.
@MainActor
final class SessionSaveCoordinator {
    private let minimumInterval: Duration
    private let clock = ContinuousClock()
    private let save: @MainActor @Sendable () async -> Void
    private var lastCompletion: ContinuousClock.Instant?
    private var task: Task<Void, Never>?
    private var pending = false
    private var generation: UInt64 = 0

    init(minimumInterval: Duration = .seconds(2), save: @escaping @MainActor @Sendable () async -> Void) {
        self.minimumInterval = minimumInterval
        self.save = save
    }

    func request() {
        pending = true
        guard task == nil else { return }
        generation &+= 1
        let requestGeneration = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == requestGeneration { self.task = nil } }
            while self.pending && !Task.isCancelled {
                if let lastCompletion = self.lastCompletion {
                    // This cancellable delay is the write-rate limit, not a state polling loop.
                    do { try await self.clock.sleep(until: lastCompletion.advanced(by: self.minimumInterval)) }
                    catch { return }
                }
                guard !Task.isCancelled else { return }
                self.pending = false
                await self.save()
                guard !Task.isCancelled, self.generation == requestGeneration else { return }
                self.lastCompletion = self.clock.now
            }
        }
    }

    /// Termination performs its own synchronous final snapshot and must retire queued requests.
    func cancel() {
        pending = false
        task?.cancel()
        task = nil
        generation &+= 1
    }
}
