import Foundation
import Testing
import Darwin

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("UniConnect SSH invocation and recovery")
struct UniConnectSSHProcessInvocationTests {
    @Test("Keeps sshpass credentials out of argv")
    func passwordUsesEnvironmentOnly() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-sshpass-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let sshpass = temporary.appendingPathComponent("sshpass")
        #expect(FileManager.default.createFile(atPath: sshpass.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sshpass.path)

        var session = DetectedSSHSession(
            destination: "root@example.test",
            port: 2222,
            identityFile: nil,
            configFile: nil,
            jumpHost: nil,
            controlPath: nil,
            useIPv4: false,
            useIPv6: false,
            forwardAgent: false,
            compressionEnabled: false,
            sshOptions: []
        )
        session.password = "not-in-argv"
        let invocation = try #require(UniConnectSSHProcessInvocation(
            session: session,
            remoteCommand: "sh -s",
            ambientEnvironment: ["PATH": temporary.path, "HOME": "/tmp"],
            sshpassPathResolver: { _ in sshpass.path }
        ))

        #expect(invocation.executable == sshpass.path)
        #expect(invocation.environment["SSHPASS"] == "not-in-argv")
        #expect(!invocation.arguments.contains(where: { $0.contains("not-in-argv") }))
        #expect(invocation.arguments.prefix(2) == ["-e", "/usr/bin/ssh"])
        #expect(invocation.environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test("Forces a separate noninteractive control connection")
    func forcesControlledSSHOptions() throws {
        let session = DetectedSSHSession(
            destination: "dev@example.test",
            port: nil,
            identityFile: "/tmp/key with space",
            configFile: nil,
            jumpHost: "jump@example.test",
            controlPath: "/tmp/user-control-socket",
            useIPv4: true,
            useIPv6: false,
            forwardAgent: true,
            compressionEnabled: true,
            sshOptions: ["StrictHostKeyChecking=no", "ControlMaster=yes"]
        )
        let invocation = try #require(UniConnectSSHProcessInvocation(
            session: session,
            remoteCommand: "sh -s",
            ambientEnvironment: ["PATH": "/usr/bin:/bin", "HOME": "/tmp"]
        ))

        #expect(invocation.executable == "/usr/bin/ssh")
        #expect(invocation.arguments.contains("ControlMaster=no"))
        #expect(invocation.arguments.contains("ControlPath=none"))
        #expect(invocation.arguments.contains("ClearAllForwardings=yes"))
        #expect(invocation.arguments.contains("ForwardAgent=no"))
        #expect(invocation.arguments.contains("PermitLocalCommand=no"))
        #expect(!invocation.arguments.contains("ControlMaster=yes"))
        #expect(!invocation.arguments.contains("-A"))
        #expect(!invocation.arguments.contains("/tmp/user-control-socket"))
        #expect(invocation.arguments.suffix(2) == ["dev@example.test", "sh -s"])
    }

    @Test("Vault-derived maintenance invocations pin the saved endpoint first")
    func pinsVaultEndpointBeforeAliasOptions() throws {
        let target = try #require(UniConnectSSHEffectiveTarget(
            user: "deploy",
            host: "server-a.example",
            port: 2208
        ))
        var session = DetectedSSHSession(
            destination: "production",
            port: nil,
            identityFile: nil,
            configFile: nil,
            jumpHost: nil,
            controlPath: nil,
            useIPv4: false,
            useIPv6: false,
            forwardAgent: false,
            compressionEnabled: false,
            sshOptions: []
        )
        session.uniConnectEffectiveTarget = target

        let invocation = try #require(UniConnectSSHProcessInvocation(
            session: session,
            remoteCommand: "tmux kill-session -t 'work'",
            ambientEnvironment: [:]
        ))

        #expect(invocation.arguments.starts(with: target.sshPinningOptions))
        #expect(invocation.arguments.suffix(2) == [
            "production",
            "tmux kill-session -t 'work'",
        ])
        #expect(!invocation.arguments.contains(where: { $0.contains("server-b.example") }))
    }

    @Test("Vault execution helpers fail closed for legacy command-only records")
    func vaultHelpersRejectMissingEffectiveTarget() {
        let legacy = UniConnectSSHCredentialRecord(
            connectCommand: "ssh production",
            effectiveTarget: nil
        )

        #expect(UniConnectSSH.processInvocation(
            credentialRecord: legacy,
            injecting: ["-T"],
            remoteCommand: "sh -s",
            ambientEnvironment: [:]
        ) == nil)
        #expect(UniConnectSSH.attachCommandLine(
            credentialRecord: legacy,
            session: "work",
            directory: nil
        ) == nil)
        #expect(UniConnectSSH.detectedSession(fromCredentialRecord: legacy) == nil)
    }

    @Test("Destructive vault subprocesses use the saved endpoint instead of the alias")
    func vaultProcessHelperPinsDestructiveCommand() throws {
        let target = try #require(UniConnectSSHEffectiveTarget(
            user: "deploy",
            host: "server-a.example",
            port: 2208
        ))
        let record = UniConnectSSHCredentialRecord(
            connectCommand: "ssh production",
            effectiveTarget: target
        )

        let invocation = try #require(UniConnectSSH.processInvocation(
            credentialRecord: record,
            injecting: ["-T"] + UniConnectSSH.baseClientOptions,
            remoteCommand: "tmux kill-session -t 'work'",
            ambientEnvironment: [:]
        ))

        #expect(invocation.arguments.starts(with: target.sshPinningOptions))
        #expect(invocation.arguments.suffix(2) == [
            "production",
            "tmux kill-session -t 'work'",
        ])
        #expect(!invocation.arguments.contains(where: { $0.contains("server-b.example") }))
    }

    @Test("Rejects a destination that could be parsed as an SSH option")
    func rejectsDestinationOptionInjection() {
        let session = DetectedSSHSession(
            destination: "-oProxyCommand=malicious",
            port: nil,
            identityFile: nil,
            configFile: nil,
            jumpHost: nil,
            controlPath: nil,
            useIPv4: false,
            useIPv6: false,
            forwardAgent: false,
            compressionEnabled: false,
            sshOptions: []
        )

        #expect(UniConnectSSHProcessInvocation(
            session: session,
            remoteCommand: "sh -s",
            ambientEnvironment: ["PATH": "/usr/bin:/bin", "HOME": "/tmp"]
        ) == nil)
    }

    @Test("Never resolves sshpass from ambient PATH")
    func ignoresAmbientPathForSSHPasswordWrapper() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-untrusted-sshpass-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let untrusted = temporary.appendingPathComponent("sshpass")
        #expect(FileManager.default.createFile(atPath: untrusted.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: untrusted.path)

        var session = DetectedSSHSession(
            destination: "root@example.test",
            port: nil,
            identityFile: nil,
            configFile: nil,
            jumpHost: nil,
            controlPath: nil,
            useIPv4: false,
            useIPv6: false,
            forwardAgent: false,
            compressionEnabled: false,
            sshOptions: []
        )
        session.password = "environment-only"
        let invocation = UniConnectSSHProcessInvocation(
            session: session,
            remoteCommand: "true",
            ambientEnvironment: ["PATH": temporary.path, "HOME": "/tmp"],
            sshpassPathResolver: { _ in nil }
        )

        #expect(invocation == nil)
    }

    @Test("Trusted sshpass resolver checks only the fixed allow-list")
    func trustedResolverHasNoPathOrMacPortsFallback() {
        var visited: [String] = []
        let result = UniConnectSSHConnectCommandValidator.trustedSSHpassExecutable { candidate in
            visited.append(candidate)
            return false
        }
        #expect(result == nil)
        #expect(visited == [
            "/opt/homebrew/bin/sshpass",
            "/usr/local/bin/sshpass",
            "/usr/bin/sshpass",
        ])
        #expect(!visited.contains("/opt/local/bin/sshpass"))
    }

    @Test("Timeout terminates the complete maintenance process group")
    func timeoutTerminatesDescendants() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-process-group-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let childPIDFile = temporary.appendingPathComponent("child.pid")
        let invocation = try #require(UniConnectSSHProcessInvocation(
            executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; sleep 60 & echo $! > \"$PID_FILE\"; wait"],
            environment: [
                "HOME": temporary.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PID_FILE": childPIDFile.path,
            ]
        ))
        let service = UniConnectSSHCommandService()

        do {
            try await service.execute(invocation, timeout: .milliseconds(150))
            Issue.record("Expected the maintenance command to time out")
        } catch UniConnectSSHCommandService.ExecutionError.timedOut {
            // Expected: returning from the timeout also means the process group was reaped.
        } catch {
            Issue.record("Expected timedOut, received \(error)")
        }

        let rawPID = try String(contentsOf: childPIDFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let childPID = try #require(pid_t(rawPID))
        let deadline = Date().addingTimeInterval(2)
        while Darwin.kill(childPID, 0) == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(Darwin.kill(childPID, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test("Recovery uses one atomic exact-name create-or-attach", arguments: ["", "saved-session", "saved-session-extra"])
    func recoveryCreatesOnlyAnAbsentExactName(existingSession: String) async throws {
        let result = try await runTmuxFixture(existingSession: existingSession) { _ in
            UniConnectSSH.remoteRecoverableTmuxCommand(session: "saved-session", directory: nil)
        }

        let expected = existingSession == "saved-session" ? "attached:saved-session" : "created:saved-session"
        #expect(result.trace.contains(expected))
        #expect(result.trace.filter { $0 == "call:new-session" }.count == 1)
        #expect(!result.trace.contains("call:has-session"))
        #expect(!result.trace.contains("fallback:-l"))
        #expect(!result.trace.contains("unsafe-arguments"))
    }

    @Test("Saved directory seeds only new sessions without passing attach's cwd override")
    func recoveryPreservesSavedDirectoryAndExistingSessionDefaults() async throws {
        for existingSession in ["", "saved-session"] {
            let result = try await runTmuxFixture(existingSession: existingSession) { directory in
                UniConnectSSH.remoteRecoverableTmuxCommand(session: "saved-session", directory: directory)
            }

            #expect(result.trace.contains("cwd:\(result.directory)"))
            #expect(!result.trace.contains("arg:-c"))
            #expect(!result.trace.contains("fallback:-l"))
            #expect(result.trace.contains(existingSession.isEmpty ? "created:saved-session" : "attached:saved-session"))
        }
    }

    @Test("A missing saved folder still attaches an existing session")
    func missingFolderDoesNotLoseExistingSession() async throws {
        let result = try await runTmuxFixture(existingSession: "saved-session", directoryExists: false) { directory in
            UniConnectSSH.remoteRecoverableTmuxCommand(session: "saved-session", directory: directory)
        }

        #expect(result.trace.contains("attached:saved-session"))
        #expect(result.trace.contains("arg:=saved-session"))
        #expect(!result.trace.contains("call:new-session"))
        #expect(!result.trace.contains("fallback:-l"))
    }

    @Test("A missing exact session and folder leave a shell instead of selecting a prefix", arguments: ["", "saved-session-extra"])
    func missingFolderAndSessionLeaveUsableShell(existingSession: String) async throws {
        let result = try await runTmuxFixture(existingSession: existingSession, directoryExists: false) { directory in
            UniConnectSSH.remoteRecoverableTmuxCommand(session: "saved-session", directory: directory)
        }

        #expect(result.trace.contains("missing:saved-session"))
        #expect(result.trace.filter { $0 == "fallback:-l" }.count == 1)
        #expect(!result.trace.contains("call:new-session"))
    }

    @Test("Failed tmux execution reaches the fallback instead of a failed-exec exit loop", arguments: [1, 127])
    func failedTmuxExecutionLeavesUsableShell(status: Int) async throws {
        let result = try await runTmuxFixture(tmuxStatus: status) { _ in
            UniConnectSSH.remoteRecoverableTmuxCommand(session: "saved-session", directory: nil)
        }

        #expect(result.trace.filter { $0 == "call:new-session" }.count == 1)
        #expect(result.trace.filter { $0 == "fallback:-l" }.count == 1)
    }

    @Test("A missing tmux binary leaves one usable login shell")
    func missingTmuxLeavesUsableShell() async throws {
        let result = try await runTmuxFixture(tmuxAvailable: false) { _ in
            UniConnectSSH.remoteRecoverableTmuxCommand(session: "saved-session", directory: nil)
        }

        #expect(result.trace == ["fallback:-l"])
    }

    @Test("Strict import cannot attach a prefix match or create a missing session")
    func strictImportRemainsExactAndNonCreating() async throws {
        let result = try await runTmuxFixture(existingSession: "saved-session-extra", expectedStatus: 72) { _ in
            UniConnectSSH.remoteExistingTmuxCommand(session: "saved-session")
        }

        #expect(result.trace.contains("arg:=saved-session"))
        #expect(!result.trace.contains("call:new-session"))
        #expect(!result.trace.contains("call:attach-session"))
        #expect(!result.trace.contains("fallback:-l"))
    }

    @Test("Recovery remains opt-in and passes through both endpoint-pinned launchers")
    func bothLaunchersForwardRecoveryPolicy() throws {
        let target = try #require(UniConnectSSHEffectiveTarget(user: "deploy", host: "server.example", port: 22))
        let record = UniConnectSSHCredentialRecord(connectCommand: "ssh deployment-alias", effectiveTarget: target)
        let direct = try #require(UniConnectSSH.attachCommandLine(
            connectCommand: record.connectCommand,
            session: "saved-session",
            directory: nil,
            existingSessionOnly: true,
            recoverMissingSession: true,
            effectiveTarget: target
        ))
        let fromVault = try #require(UniConnectSSH.attachCommandLine(
            credentialRecord: record,
            session: "saved-session",
            directory: nil,
            existingSessionOnly: true,
            recoverMissingSession: true
        ))

        #expect(direct == fromVault)
        #expect(direct.contains(UniConnectSSH.shellQuote(
            UniConnectSSH.remoteRecoverableTmuxCommand(session: "saved-session", directory: nil)
        )))
        let strict = try #require(UniConnectSSH.attachCommandLine(
            credentialRecord: record,
            session: "saved-session",
            directory: nil,
            existingSessionOnly: true
        ))
        #expect(strict.contains(UniConnectSSH.shellQuote(UniConnectSSH.remoteExistingTmuxCommand(session: "saved-session"))))
    }

    /// Executes only synthetic tmux/login-shell programs; no SSH or real tmux is launched.
    private func runTmuxFixture(
        existingSession: String = "",
        directoryExists: Bool = true,
        tmuxAvailable: Bool = true,
        tmuxStatus: Int = 0,
        expectedStatus: Int32 = 0,
        command: (String) -> String
    ) async throws -> (trace: [String], directory: String) {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-tmux-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let directory = temporary.appendingPathComponent("saved project's directory", isDirectory: true)
        if directoryExists {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let traceURL = temporary.appendingPathComponent("trace")
        let loginShell = temporary.appendingPathComponent("login-shell")
        try "#!/bin/sh\nprintf 'fallback:%s\\n' \"$*\" >> \"$UC_TRACE\"\n".write(to: loginShell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: loginShell.path)
        if tmuxAvailable {
            let tmux = temporary.appendingPathComponent("tmux")
            let script = #"""
            #!/bin/sh
            action=$1
            shift
            if [ "$action" = set-option ] && [ "$#" -ge 5 ]; then
                [ "$1" = -g ] && [ "$2" = history-limit ] && [ "$3" = 50000 ] && [ "$4" = ';' ] || exit 65
                shift 4
                action=$1
                shift
            fi
            printf 'call:%s\n' "$action" >> "$UC_TRACE"
            printf 'arg:%s\n' "$@" >> "$UC_TRACE"
            case "$action" in
            new-session)
                [ "$1" = -A ] && [ "$2" = -s ] || { printf 'unsafe-arguments\n' >> "$UC_TRACE"; exit 65; }
                name=$3
                shift 3
                for argument do
                    case "$argument" in -c|-D|-d|-X|kill-session|kill-server|send-keys)
                        printf 'unsafe-arguments\n' >> "$UC_TRACE"; exit 65;;
                    esac
                done
                printf 'cwd:%s\n' "$(pwd -P)" >> "$UC_TRACE"
                [ "$UC_STATUS" = 0 ] || exit "$UC_STATUS"
                if [ "$UC_EXISTING" = "$name" ]; then
                    printf 'attached:%s\n' "$name" >> "$UC_TRACE"
                else
                    printf 'created:%s\n' "$name" >> "$UC_TRACE"
                fi
                ;;
            attach-session|has-session)
                [ "$1" = -t ] || exit 65
                case "$2" in =*) name=${2#=};; *) printf 'unsafe-arguments\n' >> "$UC_TRACE"; exit 65;; esac
                if [ "$UC_EXISTING" != "$name" ]; then
                    printf 'missing:%s\n' "$name" >> "$UC_TRACE"
                    exit 1
                fi
                if [ "$action" = attach-session ]; then
                    printf 'attached:%s\n' "$name" >> "$UC_TRACE"
                fi
                ;;
            set-option) ;;
            *) printf 'unsafe-arguments\n' >> "$UC_TRACE"; exit 65;;
            esac
            """#
            try script.write(to: tmux, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmux.path)
        }
        let invocation = try #require(UniConnectSSHProcessInvocation(
            executable: "/bin/sh",
            arguments: ["-c", command(directory.path)],
            environment: [
                "PATH": temporary.path,
                "SHELL": loginShell.path,
                "UC_TRACE": traceURL.path,
                "UC_EXISTING": existingSession,
                "UC_STATUS": String(tmuxStatus),
            ]
        ))
        do {
            try await UniConnectSSHCommandService().execute(invocation, timeout: .seconds(3))
            #expect(expectedStatus == 0)
        } catch UniConnectSSHCommandService.ExecutionError.failed(let status) {
            #expect(status == expectedStatus)
        }
        let trace = try String(contentsOf: traceURL, encoding: .utf8).split(separator: "\n").map(String.init)
        return (trace, directory.resolvingSymlinksInPath().path)
    }
}
