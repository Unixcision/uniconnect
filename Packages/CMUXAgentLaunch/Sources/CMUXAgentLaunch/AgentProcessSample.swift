import Foundation

/// One row of the process table the agent discovery reads.
///
/// It mirrors `ps -eo pid=,ppid=,uid=,args=` (or `/proc`): no environment, no open files. The
/// discovery only needs parentage, the owner and the argument vector to find which agent a tmux
/// pane is running.
public struct AgentProcessSample: Sendable, Equatable, Codable {
    /// The process id.
    public let pid: Int
    /// The parent process id.
    public let parentPID: Int
    /// The real user id; `0` means the agent runs as root.
    public let userID: Int
    /// The argument vector, executable first. Empty when it could not be read.
    public let arguments: [String]

    /// Creates a process row.
    ///
    /// - Parameters:
    ///   - pid: The process id.
    ///   - parentPID: The parent process id.
    ///   - userID: The real user id.
    ///   - arguments: The argument vector, executable first.
    public init(pid: Int, parentPID: Int, userID: Int, arguments: [String]) {
        self.pid = pid
        self.parentPID = parentPID
        self.userID = userID
        self.arguments = arguments
    }

    /// The last path component of `argv[0]`, without a login shell's leading `-`.
    public var executableName: String {
        guard let first = arguments.first else { return "" }
        let name = (first as NSString).lastPathComponent
        return name.hasPrefix("-") ? String(name.dropFirst()) : name
    }
}
