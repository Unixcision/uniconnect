import Foundation

/// Kernel process identity; the start timestamp prevents granting access to a recycled PID.
struct UniConnectLocalTmuxProcessIdentity: Equatable, Sendable {
    let pid: Int
    let parentPID: Int
    let userID: UInt32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}
