import Foundation

/// Bridges injected NotificationCenter terminal transitions into an asynchronous stream.
actor UniConnectClaudeSessionSignalSource: UniConnectClaudeSessionSignalStreaming {
    private let center: NotificationCenter

    init(center: NotificationCenter) {
        self.center = center
    }

    func signals() -> AsyncStream<UniConnectClaudeSessionSignal> {
        let center = center
        return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            let token = center.addObserver(
                forName: .uniConnectClaudeSessionSignal,
                object: nil,
                queue: nil
            ) { notification in
                guard let signal = notification.object as? UniConnectClaudeSessionSignal else {
                    return
                }
                continuation.yield(signal)
            }
            continuation.onTermination = { @Sendable _ in
                center.removeObserver(token)
            }
        }
    }
}
