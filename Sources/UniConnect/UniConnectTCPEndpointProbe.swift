import Foundation
import Network
import os

/// Checks an SSH endpoint with a plain TCP connection: no SSH handshake, no credentials sent.
struct UniConnectTCPEndpointProbe: UniConnectSSHEndpointProbing {
    /// Longest wait for the TCP handshake.
    let timeout: Duration

    init(timeout: Duration = .seconds(5)) {
        self.timeout = timeout
    }

    func answers(host: String, port: Int) async -> Bool {
        guard (1...65_535).contains(port),
              let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return false
        }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = max(1, Int(timeout.components.seconds))
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: endpointPort,
            using: NWParameters(tls: nil, tcp: tcp)
        )
        let timeout = timeout
        return await withCheckedContinuation { continuation in
            // One-shot resume guard: connection states and the deadline race to answer once.
            let claimed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (Bool) -> Void = { answered in
                let first = claimed.withLock { alreadyClaimed -> Bool in
                    defer { alreadyClaimed = true }
                    return !alreadyClaimed
                }
                guard first else { return }
                connection.cancel()
                continuation.resume(returning: answered)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .failed, .waiting, .cancelled:
                    finish(false)
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "uniconnect.ssh-endpoint-probe"))
            Task {
                // Bounded deadline, the intended behavior: a host that never answers is "down".
                try? await Task.sleep(for: timeout + .seconds(1))
                finish(false)
            }
        }
    }
}
