import Foundation

/// What the local relaunch needs from this Mac's processes: read them and signal them.
///
/// A seam, so the whole local Claude flow can be exercised in tests with a fake process table and
/// without a real agent being closed.
protocol UniConnectRelaunchProcessInspecting: Sendable {
    /// Every live process, or `nil` when the table could not be read (never an empty guess).
    func processes() -> [UniConnectRelaunchProcessInfo]?
    /// The real argv and environment of a process, as the kernel holds them.
    func arguments(of pid: Int32) -> (argv: [String], environment: [String: String])?
    /// The process's working directory.
    func workingDirectory(of pid: Int32) -> String?
    /// The process's executable path.
    func executablePath(of pid: Int32) -> String?
    /// Sends `signal` to one process; `false` when it is gone or cannot be signalled.
    @discardableResult
    func signal(_ signal: Int32, to pid: Int32) -> Bool
    /// Sends `signal` to a whole process group.
    @discardableResult
    func signal(_ signal: Int32, toGroup group: Int32) -> Bool
    /// Waits for a process to exit, up to `timeout`; `true` once it is gone.
    func waitForExit(of pid: Int32, timeout: Duration) async -> Bool
}
