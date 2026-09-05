import CMUXAgentLaunch
import Foundation

/// Test-only standalone process: emits reconstructed argv without launching an agent.
@main
struct AgentResumeProbe {
    static func main() throws {
        let argv = AgentResumeArgv().builtInKind(kind: "codex", sessionId: "SID", executablePath: nil, arguments: [])
        try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(argv))
    }
}
