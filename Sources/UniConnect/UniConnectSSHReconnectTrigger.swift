import Foundation

/// Distinguishes bounded automatic recovery from an explicit user-forced SSH reconnect.
enum UniConnectSSHReconnectTrigger: Equatable, Sendable {
    case automatic
    case userForced
}
