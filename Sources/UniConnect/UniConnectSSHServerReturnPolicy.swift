import Foundation

/// Decides, check after check, whether an SSH window whose automatic reconnects ran out gets a
/// fresh budget (`contracts/ssh-server-return-v1`).
///
/// The input is only whether the server's SSH port answered a TCP connection. A window whose
/// server was seen unreachable re-arms as soon as it answers again; a window whose server kept
/// answering (the failure was not the network) gets one extra attempt and then stops, so a
/// rejected login never turns into an endless retry loop.
struct UniConnectSSHServerReturnPolicy: Equatable, Sendable {
    /// What the window does after one check.
    enum Decision: String, Equatable, Sendable {
        /// Fresh reconnect budget and an immediate reconnect.
        case rearm = "rearmar"
        /// Still unreachable: check again at the next interval.
        case keepWaiting = "esperar"
        /// The server answered and the window still did not attach: leave it to the person.
        case stop = "parar"
    }

    private var sawServerDown = false
    private var usedAnsweringRetry = false

    /// Feeds one check and returns the decision; the state persists across waits.
    mutating func observe(serverAnswers: Bool) -> Decision {
        guard serverAnswers else {
            sawServerDown = true
            return .keepWaiting
        }
        if sawServerDown {
            sawServerDown = false
            return .rearm
        }
        if !usedAnsweringRetry {
            usedAnsweringRetry = true
            return .rearm
        }
        return .stop
    }
}
