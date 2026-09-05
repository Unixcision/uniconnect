import Foundation
import UniConnectClaudeUpdate

/// Executes local or remote Claude version/update commands through bounded child processes.
actor UniConnectClaudeBinaryUpdater: ClaudeBinaryUpdating {
    enum UpdaterError: Error, Sendable, Equatable {
        case invalidHost
        case missingCredential
        case invalidCredential
        case invalidExecutable
        case versionUnavailable
        case processFailure
    }

    typealias CredentialResolver = @Sendable (UUID) async -> UniConnectSSHCredentialRecord?

    private let processRunner: any UniConnectProcessRunning
    private let credentialResolver: CredentialResolver
    private let ambientEnvironment: @Sendable () -> [String: String]
    private let parser: ClaudeUpdateOutputParser

    init(
        processRunner: any UniConnectProcessRunning,
        credentialResolver: @escaping CredentialResolver,
        ambientEnvironment: @escaping @Sendable () -> [String: String] = {
            ProcessInfo.processInfo.environment
        },
        parser: ClaudeUpdateOutputParser = ClaudeUpdateOutputParser()
    ) {
        self.processRunner = processRunner
        self.credentialResolver = credentialResolver
        self.ambientEnvironment = ambientEnvironment
        self.parser = parser
    }

    func installedVersion(
        on host: ClaudeUpdateHostIdentity,
        executablePath: String
    ) async throws -> ClaudeVersion {
        try validateExecutable(executablePath)
        let result: UniConnectProcessResult
        switch host.kind {
        case .local:
            guard host.id == UniConnectClaudeUpdateHostID.local else {
                throw UpdaterError.invalidHost
            }
            result = try await processRunner.run(
                executable: executablePath,
                arguments: ["--version"],
                environment: localEnvironment(),
                standardInput: nil,
                timeout: .seconds(20)
            )
        case .remote:
            result = try await runRemote(
                host: host,
                executablePath: executablePath,
                operation: .version
            )
        }
        guard result.terminationStatus == 0, !result.outputWasTruncated else {
            throw UpdaterError.versionUnavailable
        }
        let output = Self.sanitizedOutput(result.standardOutput, result.standardError)
        guard let version = parser.parseVersion(output) else {
            throw UpdaterError.versionUnavailable
        }
        return version
    }

    func update(
        on host: ClaudeUpdateHostIdentity,
        executablePath: String
    ) async throws -> ClaudeUpdateCommandResult {
        try validateExecutable(executablePath)
        do {
            let result: UniConnectProcessResult
            switch host.kind {
            case .local:
                guard host.id == UniConnectClaudeUpdateHostID.local else {
                    throw UpdaterError.invalidHost
                }
                result = try await processRunner.run(
                    executable: executablePath,
                    arguments: ["update"],
                    environment: localEnvironment(),
                    standardInput: nil,
                    timeout: .seconds(180)
                )
            case .remote:
                result = try await runRemote(
                    host: host,
                    executablePath: executablePath,
                    operation: .update
                )
            }
            let output = Self.sanitizedOutputPair(result.standardOutput, result.standardError)
            return ClaudeUpdateCommandResult(
                exitCode: result.terminationStatus,
                didTimeOut: false,
                standardOutput: result.outputWasTruncated ? "" : output.stdout,
                standardError: result.outputWasTruncated ? "output_truncated" : output.stderr
            )
        } catch UniConnectProcessRunnerError.timedOut {
            return ClaudeUpdateCommandResult(
                exitCode: -1,
                didTimeOut: true,
                standardOutput: "",
                standardError: "deadline_exceeded"
            )
        } catch UniConnectProcessRunnerError.cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as UpdaterError {
            throw error
        } catch {
            throw UpdaterError.processFailure
        }
    }

    private enum RemoteOperation {
        case version
        case update
    }

    private func runRemote(
        host: ClaudeUpdateHostIdentity,
        executablePath: String,
        operation: RemoteOperation
    ) async throws -> UniConnectProcessResult {
        guard let credentialID = UniConnectClaudeUpdateHostID.credentialID(from: host.id) else {
            throw UpdaterError.invalidHost
        }
        guard let expectedEndpointFingerprint = UniConnectClaudeUpdateHostID.endpointFingerprint(
            from: host.id
        ) else {
            throw UpdaterError.invalidHost
        }
        guard let credentialRecord = await credentialResolver(credentialID) else {
            throw UpdaterError.missingCredential
        }
        guard let effectiveTarget = credentialRecord.effectiveTarget,
              let session = UniConnectSSH.detectedSession(
                  fromCredentialRecord: credentialRecord
              ) else {
            throw UpdaterError.invalidCredential
        }
        guard UniConnectClaudeUpdateHostID.endpointFingerprint(for: effectiveTarget)
                == expectedEndpointFingerprint else {
            throw UpdaterError.invalidCredential
        }

        let remoteCommand = "sh -s -- " + UniConnectSSH.shellQuote(executablePath)
        guard let invocation = UniConnectSSHProcessInvocation(
            session: session,
            remoteCommand: remoteCommand,
            ambientEnvironment: ambientEnvironment()
        ) else {
            throw UpdaterError.invalidCredential
        }
        let script: String
        let timeout: Duration
        switch operation {
        case .version:
            script = Self.remoteVersionScript
            timeout = .seconds(30)
        case .update:
            script = Self.remoteUpdateScript
            timeout = .seconds(180)
        }
        return try await processRunner.run(
            executable: invocation.executable,
            arguments: invocation.arguments,
            environment: invocation.environment,
            standardInput: Data(script.utf8),
            timeout: timeout
        )
    }

    private func validateExecutable(_ executablePath: String) throws {
        guard executablePath.hasPrefix("/"),
              !executablePath.contains("\0"),
              executablePath.utf8.count <= 4_096 else {
            throw UpdaterError.invalidExecutable
        }
    }

    private func localEnvironment() -> [String: String] {
        let ambient = ambientEnvironment()
        let directKeys = [
            "HOME", "USER", "LOGNAME", "PATH", "SHELL", "TMPDIR", "LANG",
            "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME",
            "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy",
        ]
        var result: [String: String] = [:]
        for key in directKeys {
            if let value = ambient[key], !value.contains("\0") { result[key] = value }
        }
        for (key, value) in ambient where key.hasPrefix("LC_") && !value.contains("\0") {
            result[key] = value
        }
        result["TERM"] = "dumb"
        return result
    }

    private static func sanitizedOutput(_ stdout: Data, _ stderr: Data) -> String {
        let pair = sanitizedOutputPair(stdout, stderr)
        return pair.stdout + "\n" + pair.stderr
    }

    private static func sanitizedOutputPair(
        _ stdout: Data,
        _ stderr: Data
    ) -> (stdout: String, stderr: String) {
        (
            sanitize(String(decoding: stdout, as: UTF8.self)),
            sanitize(String(decoding: stderr, as: UTF8.self))
        )
    }

    private static func sanitize(_ value: String) -> String {
        let withoutOSC = value.replacingOccurrences(
            of: "\u{001B}\\][^\u{0007}\u{001B}]*(?:\u{0007}|\u{001B}\\\\)",
            with: "",
            options: .regularExpression
        )
        let withoutCSI = withoutOSC.replacingOccurrences(
            of: "\u{001B}\\[[0-?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
        return String(withoutCSI.unicodeScalars.filter { scalar in
            scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0D || scalar.value >= 0x20
        }).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let remoteVersionScript = """
    set -eu
    executable=$1
    case "$executable" in /*) ;; *) exit 64 ;; esac
    [ -x "$executable" ] || exit 65
    exec "$executable" --version
    """

    private static let remoteUpdateScript = """
    set -eu
    executable=$1
    case "$executable" in /*) ;; *) exit 64 ;; esac
    [ -x "$executable" ] || exit 65
    exec "$executable" update </dev/null
    """
}
