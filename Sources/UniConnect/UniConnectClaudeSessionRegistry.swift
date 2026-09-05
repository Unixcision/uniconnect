import Foundation
import UniConnectClaudeBridge

/// Multiplexes one-shot Claude streams into per-surface-generation event subscriptions.
actor UniConnectClaudeSessionRegistry {
    private struct Subscriber {
        let workspaceID: UUID
        let panelID: UUID
        let surfaceGeneration: UUID?
        let continuation: AsyncStream<UniConnectClaudeSessionEvent>.Continuation
    }

    private var latestRemoteSignals: [UUID: ClaudeBridgeSessionSignal] = [:]
    private var subscribers: [UUID: Subscriber] = [:]
    private var localPump: Task<Void, Never>?
    private var remotePump: Task<Void, Never>?

    func start(
        localSignals: any UniConnectClaudeSessionSignalStreaming,
        remoteSignals: AsyncStream<ClaudeBridgeSessionSignal>?
    ) {
        guard localPump == nil, remotePump == nil else { return }
        localPump = Task { [weak self, localSignals] in
            let stream = await localSignals.signals()
            for await signal in stream {
                guard !Task.isCancelled else { return }
                await self?.record(local: signal)
            }
        }
        if let remoteSignals {
            remotePump = Task { [weak self, remoteSignals] in
                for await signal in remoteSignals {
                    guard !Task.isCancelled else { return }
                    await self?.record(remote: signal)
                }
            }
        }
    }

    func stop() {
        localPump?.cancel()
        remotePump?.cancel()
        localPump = nil
        remotePump = nil
        for subscriber in subscribers.values {
            subscriber.continuation.finish()
        }
        subscribers.removeAll()
    }

    func latestRemoteSignal(routeID: UUID) -> ClaudeBridgeSessionSignal? {
        latestRemoteSignals[routeID]
    }

    func events(
        workspaceID: UUID,
        panelID: UUID,
        surfaceGeneration: UUID? = nil
    ) -> AsyncStream<UniConnectClaudeSessionEvent> {
        let subscriptionID = UUID()
        let pair = AsyncStream<UniConnectClaudeSessionEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )
        subscribers[subscriptionID] = Subscriber(
            workspaceID: workspaceID,
            panelID: panelID,
            surfaceGeneration: surfaceGeneration,
            continuation: pair.continuation
        )
        pair.continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeSubscriber(subscriptionID) }
        }
        return pair.stream
    }

    private func record(local signal: UniConnectClaudeSessionSignal) {
        for subscriber in subscribers.values
        where subscriber.workspaceID == signal.workspaceID
            && subscriber.panelID == signal.panelID
            && (subscriber.surfaceGeneration == nil
                || subscriber.surfaceGeneration == signal.surfaceGeneration) {
            subscriber.continuation.yield(.local(signal))
        }
    }

    private func record(remote signal: ClaudeBridgeSessionSignal) {
        if let existing = latestRemoteSignals[signal.routeID], existing.occurredAt > signal.occurredAt {
            return
        }
        latestRemoteSignals[signal.routeID] = signal
        for subscriber in subscribers.values where subscriber.panelID == signal.routeID {
            subscriber.continuation.yield(.remote(signal))
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }
}
