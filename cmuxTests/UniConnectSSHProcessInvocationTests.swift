import Foundation
import Testing
import Darwin

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("UniConnect updater SSH invocation")
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
}
