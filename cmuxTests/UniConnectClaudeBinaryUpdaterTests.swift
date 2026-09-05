import Foundation
import Testing
import UniConnectClaudeUpdate

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("UniConnect Claude binary updater")
struct UniConnectClaudeBinaryUpdaterTests {
    private struct Request: Sendable {
        let executable: String
        let arguments: [String]
        let environment: [String: String]
        let standardInput: Data?
        let timeout: Duration
    }

    private actor ProcessRunner: UniConnectProcessRunning {
        private var responses: [Result<UniConnectProcessResult, UniConnectProcessRunnerError>]
        private(set) var requests: [Request] = []

        init(_ responses: [Result<UniConnectProcessResult, UniConnectProcessRunnerError>]) {
            self.responses = responses
        }

        func run(
            executable: String,
            arguments: [String],
            environment: [String: String],
            standardInput: Data?,
            timeout: Duration
        ) async throws -> UniConnectProcessResult {
            requests.append(Request(
                executable: executable,
                arguments: arguments,
                environment: environment,
                standardInput: standardInput,
                timeout: timeout
            ))
            guard !responses.isEmpty else { throw UniConnectProcessRunnerError.launchFailed }
            return try responses.removeFirst().get()
        }
    }

    private let localHost = ClaudeUpdateHostIdentity(
        kind: .local,
        id: UniConnectClaudeUpdateHostID.local,
        displayName: "Local"
    )

    @Test("Reads the exact executable version without a shell")
    func readsLocalVersion() async throws {
        let runner = ProcessRunner([.success(.init(
            terminationStatus: 0,
            standardOutput: Data("2.7.1 (Claude Code)\n".utf8),
            standardError: Data(),
            outputWasTruncated: false
        ))])
        let updater = UniConnectClaudeBinaryUpdater(
            processRunner: runner,
            credentialResolver: { _ in nil },
            ambientEnvironment: { [
                "PATH": "/usr/bin:/bin",
                "HOME": "/tmp/home",
                "CLAUDECODE": "must-not-leak",
                "CLAUDE_CONFIG_DIR": "/tmp/unbound-config",
                "ANTHROPIC_API_KEY": "must-not-leak",
            ] }
        )

        let version = try await updater.installedVersion(
            on: localHost,
            executablePath: "/opt/claude/bin/claude"
        )
        #expect(version == ClaudeVersion(major: 2, minor: 7, patch: 1))
        let requests = await runner.requests
        let request = try #require(requests.first)
        #expect(request.executable == "/opt/claude/bin/claude")
        #expect(request.arguments == ["--version"])
        #expect(request.standardInput == nil)
        #expect(request.environment["CLAUDECODE"] == nil)
        #expect(request.environment["CLAUDE_CONFIG_DIR"] == nil)
        #expect(request.environment["ANTHROPIC_API_KEY"] == nil)
    }

    @Test("Returns sanitized controlled update output")
    func returnsSanitizedUpdateOutput() async throws {
        let runner = ProcessRunner([.success(.init(
            terminationStatus: 0,
            standardOutput: Data("\u{001B}[32mAlready up to date\u{001B}[0m\n".utf8),
            standardError: Data(),
            outputWasTruncated: false
        ))])
        let updater = UniConnectClaudeBinaryUpdater(
            processRunner: runner,
            credentialResolver: { _ in nil }
        )

        let result = try await updater.update(
            on: localHost,
            executablePath: "/opt/claude/bin/claude"
        )
        #expect(result.exitCode == 0)
        #expect(!result.didTimeOut)
        #expect(result.standardOutput == "Already up to date")
        #expect(result.standardError.isEmpty)
    }

    @Test("Represents a deadline as a verifiable timeout result")
    func mapsDeadline() async throws {
        let runner = ProcessRunner([.failure(.timedOut)])
        let updater = UniConnectClaudeBinaryUpdater(
            processRunner: runner,
            credentialResolver: { _ in nil }
        )

        let result = try await updater.update(
            on: localHost,
            executablePath: "/opt/claude/bin/claude"
        )
        #expect(result.exitCode == -1)
        #expect(result.didTimeOut)
        #expect(result.standardError == "deadline_exceeded")
    }

    @Test("Rejects nonabsolute executable identity before launching")
    func rejectsRelativeExecutable() async {
        let runner = ProcessRunner([])
        let updater = UniConnectClaudeBinaryUpdater(
            processRunner: runner,
            credentialResolver: { _ in nil }
        )

        await #expect(throws: UniConnectClaudeBinaryUpdater.UpdaterError.invalidExecutable) {
            try await updater.installedVersion(on: localHost, executablePath: "claude")
        }
        let requests = await runner.requests
        #expect(requests.isEmpty)
    }

    @Test("Rejects a credential revision that resolves to a different SSH endpoint")
    func rejectsRetargetedCredential() async {
        let credentialID = UUID()
        let original = try! #require(UniConnectSSHEffectiveTarget(
            user: "owner",
            host: "original.example",
            port: 22
        ))
        let different = try! #require(UniConnectSSHEffectiveTarget(
            user: "owner",
            host: "different.example",
            port: 22
        ))
        let host = ClaudeUpdateHostIdentity(
            kind: .remote,
            id: UniConnectClaudeUpdateHostID.remote(
                credentialID: credentialID,
                endpointFingerprint: UniConnectClaudeUpdateHostID.endpointFingerprint(for: original)
            ),
            displayName: "Original"
        )
        let runner = ProcessRunner([])
        let updater = UniConnectClaudeBinaryUpdater(
            processRunner: runner,
            credentialResolver: { requestedID in
                requestedID == credentialID
                    ? UniConnectSSHCredentialRecord(
                        connectCommand: "ssh production",
                        effectiveTarget: different
                    )
                    : nil
            }
        )

        await #expect(throws: UniConnectClaudeBinaryUpdater.UpdaterError.invalidCredential) {
            try await updater.installedVersion(on: host, executablePath: "/usr/bin/claude")
        }
        #expect(await runner.requests.isEmpty)
    }

    @Test("Pins remote updater commands to the encrypted endpoint revision")
    func pinsRemoteUpdaterToSavedEndpoint() async throws {
        let credentialID = UUID()
        let target = try #require(UniConnectSSHEffectiveTarget(
            user: "owner",
            host: "server-a.example",
            port: 2207
        ))
        let host = ClaudeUpdateHostIdentity(
            kind: .remote,
            id: UniConnectClaudeUpdateHostID.remote(
                credentialID: credentialID,
                endpointFingerprint: UniConnectClaudeUpdateHostID.endpointFingerprint(for: target)
            ),
            displayName: "Production"
        )
        let runner = ProcessRunner([.success(.init(
            terminationStatus: 0,
            standardOutput: Data("2.7.1 (Claude Code)\n".utf8),
            standardError: Data(),
            outputWasTruncated: false
        ))])
        let updater = UniConnectClaudeBinaryUpdater(
            processRunner: runner,
            credentialResolver: { requestedID in
                requestedID == credentialID
                    ? UniConnectSSHCredentialRecord(
                        connectCommand: "ssh production",
                        effectiveTarget: target
                    )
                    : nil
            }
        )

        _ = try await updater.installedVersion(
            on: host,
            executablePath: "/usr/bin/claude"
        )
        let requests = await runner.requests
        let request = try #require(requests.first)
        #expect(request.arguments.starts(with: target.sshPinningOptions))
        #expect(!request.arguments.contains(where: { $0.contains("server-b.example") }))
        #expect(request.arguments.suffix(2) == ["production", "sh -s -- '/usr/bin/claude'"])
    }
}
