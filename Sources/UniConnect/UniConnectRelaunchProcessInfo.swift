import Foundation

/// One live process of this Mac, as the relaunch needs to know it.
///
/// The start time is part of the identity: a pid alone is reused by the kernel, so "the same pid"
/// is never taken as "the same process" (`UniConnectRelaunchAgentProcess`).
struct UniConnectRelaunchProcessInfo: Sendable, Equatable {
    let pid: Int32
    let parent: Int32
    let group: Int32
    let userID: UInt32
    /// When the kernel says the process started, to the microsecond.
    let start: Date
    /// The short command name (`claude`, `zsh`).
    let name: String

    /// Whether `other` is this very process: same pid and same start.
    func isSameProcess(as other: UniConnectRelaunchProcessInfo) -> Bool {
        pid == other.pid && start == other.start
    }
}
