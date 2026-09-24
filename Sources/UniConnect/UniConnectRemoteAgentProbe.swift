import CMUXAgentLaunch
import Foundation

/// Reads, over a box's own SSH channel, which agent runs in each tmux session of that host.
///
/// It runs the shared, read-only `agent_probe.py` (bundled from `linux/uniconnect/`) as
/// `python3 - --socket default`, with the script on stdin, through the same pinned SSH invocation
/// every other UniConnect remote probe uses. One connection per call, at most 10 s and 256 KiB of
/// JSON plus its final newline (``AgentProbeReport/maximumOutputBytes``). Any failure — no
/// credential, no script in the bundle, no python3, a timeout, a malformed or version-2 report —
/// yields `nil`, and callers then change nothing.
actor UniConnectRemoteAgentProbe {
    typealias CredentialResolver = @Sendable (UUID) async -> UniConnectSSHCredentialRecord?

    private let processRunner: any UniConnectProcessRunning
    private let credentialResolver: CredentialResolver
    private let probeScript: @Sendable () -> String?
    private let ambientEnvironment: @Sendable () -> [String: String]
    private let timeout: Duration
    /// The largest probe output accepted, for the runner that carries it (262 144 bytes + `\n`).
    static let maximumOutputBytes = AgentProbeReport.maximumOutputBytes

    init(
        processRunner: any UniConnectProcessRunning,
        credentialResolver: @escaping CredentialResolver,
        probeScript: @escaping @Sendable () -> String? = {
            UniConnectRemoteAgentProbe.bundledScript(named: "agent_probe")
        },
        ambientEnvironment: @escaping @Sendable () -> [String: String] = {
            ProcessInfo.processInfo.environment
        },
        timeout: Duration = .seconds(10)
    ) {
        self.processRunner = processRunner
        self.credentialResolver = credentialResolver
        self.probeScript = probeScript
        self.ambientEnvironment = ambientEnvironment
        self.timeout = timeout
    }

    /// Probes one box's tmux server.
    ///
    /// - Parameters:
    ///   - credentialID: The box's vault credential.
    ///   - socket: The tmux socket; `default` is the server `ssh` sessions attach to.
    ///   - timeout: An optional shorter deadline (Detalles uses 8 s).
    /// - Returns: The decoded report, or `nil` on any failure.
    func probe(credentialID: UUID, socket: String = "default", timeout deadline: Duration? = nil) async -> AgentProbeReport? {
        guard let script = probeScript(), !script.isEmpty,
              let record = await credentialResolver(credentialID),
              let session = UniConnectSSH.detectedSession(fromCredentialRecord: record) else { return nil }
        let remoteCommand = "python3 - --socket " + UniConnectSSH.shellQuote(socket)
        guard let invocation = UniConnectSSHProcessInvocation(
            session: session,
            remoteCommand: remoteCommand,
            ambientEnvironment: ambientEnvironment()
        ) else { return nil }
        guard let result = try? await processRunner.run(
            executable: invocation.executable,
            arguments: invocation.arguments,
            environment: invocation.environment,
            standardInput: Data(script.utf8),
            timeout: deadline ?? timeout
        ), result.terminationStatus == 0, !result.outputWasTruncated else { return nil }
        // The probe guarantees at most 262 144 bytes of JSON plus its final "\n".
        return AgentProbeReport.decode(output: result.standardOutput)
    }

    /// The text of a helper script bundled from `linux/uniconnect/` (`agent_probe`, `agent_guard`).
    nonisolated static func bundledScript(named name: String, bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: name, withExtension: "py"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              text.utf8.count <= 256 * 1_024 else { return nil }
        return text
    }
}
