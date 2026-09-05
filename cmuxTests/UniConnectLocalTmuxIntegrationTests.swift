import CmuxProcess
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Real local tmux lifecycle", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["CI"] == "true", "Real PTY integration runs only in CI"))
struct UniConnectLocalTmuxIntegrationTests {
    @Test("Detach and reattach preserve the pane PID and native launch; missing sessions recreate once")
    func realAttachAndMissingSessionRecovery() async throws {
        let fixture = try Fixture()
        do {
            let binding = fixture.binding(name: "primary")
            let panelID = UUID(), firstGeneration = UUID(), nextGeneration = UUID()
            let firstDirectory = try fixture.directory("first 'project'")
            let secondDirectory = try fixture.directory("second project")
            let counter = fixture.root.appendingPathComponent("launch-count")
            let initialCommand = fixture.agentCommand(counter: counter)
            let firstClient = try fixture.launch(
                binding: binding, directory: firstDirectory.path, command: initialCommand,
                panelID: panelID, generation: firstGeneration
            )
            let firstPane = try await fixture.attachedPane(binding)
            try await fixture.waitForLaunchCount(counter, expected: 1)
            #expect(try await fixture.environment("CMUX_SURFACE_ID", binding) == panelID.uuidString)
            #expect(try await fixture.environment("UNICONNECT_SURFACE_GENERATION", binding) == firstGeneration.uuidString)
            try await fixture.detach(binding, client: firstClient)
            let detachedPane = try await fixture.pane(binding)
            #expect(detachedPane.sessionID == firstPane.sessionID)
            #expect(detachedPane.pid == firstPane.pid)

            let secondClient = try fixture.launch(
                binding: binding, directory: secondDirectory.path, command: initialCommand,
                panelID: panelID, generation: nextGeneration
            )
            let secondPane = try await fixture.attachedPane(binding)
            #expect(secondPane.sessionID == firstPane.sessionID)
            #expect(secondPane.pid == firstPane.pid)
            #expect(try fixture.canonicalPath(secondPane.directory) == fixture.canonicalPath(firstDirectory.path))
            #expect(try await fixture.environment("UNICONNECT_SURFACE_GENERATION", binding) == firstGeneration.uuidString)
            #expect(try fixture.launchCount(counter) == 1)
            try await fixture.detach(binding, client: secondClient)

            // This is the only destructive operation under test: the freshly generated,
            // dedicated fixture session, never a production/default tmux socket.
            _ = try await fixture.command(["kill-session", "-t", "=" + binding.name])
            let thirdClient = try fixture.launch(
                binding: binding, directory: secondDirectory.path, command: initialCommand,
                panelID: panelID, generation: nextGeneration
            )
            let thirdPane = try await fixture.attachedPane(binding)
            try await fixture.waitForLaunchCount(counter, expected: 2)
            // A server may reuse session numbers after its final session exits, so pane
            // process identity is the durable proof of replacement across that boundary.
            #expect(thirdPane.pid != firstPane.pid)
            #expect(try fixture.canonicalPath(thirdPane.directory) == fixture.canonicalPath(secondDirectory.path))
            #expect(try await fixture.environment("UNICONNECT_SURFACE_GENERATION", binding) == nextGeneration.uuidString)
            try await fixture.detach(binding, client: thirdClient)
            #expect(try await fixture.pane(binding).pid == thirdPane.pid)
            await fixture.cleanup()
        } catch {
            await fixture.cleanup()
            throw error
        }
    }

    @Test("A second session on the same real server receives its own pane context")
    func realServerDoesNotLeakFirstWindowEnvironment() async throws {
        let fixture = try Fixture()
        do {
            let first = fixture.binding(name: "first"), second = fixture.binding(name: "second")
            let firstPanel = UUID(), secondPanel = UUID(), firstGeneration = UUID(), secondGeneration = UUID()
            let firstClient = try fixture.launch(
                binding: first, directory: fixture.root.path, command: nil,
                panelID: firstPanel, generation: firstGeneration
            )
            _ = try await fixture.attachedPane(first)
            let secondClient = try fixture.launch(
                binding: second, directory: fixture.root.path, command: nil,
                panelID: secondPanel, generation: secondGeneration
            )
            _ = try await fixture.attachedPane(second)
            #expect(try await fixture.environment("CMUX_SURFACE_ID", first) == firstPanel.uuidString)
            #expect(try await fixture.environment("CMUX_SURFACE_ID", second) == secondPanel.uuidString)
            #expect(try await fixture.environment("UNICONNECT_SURFACE_GENERATION", first) == firstGeneration.uuidString)
            #expect(try await fixture.environment("UNICONNECT_SURFACE_GENERATION", second) == secondGeneration.uuidString)
            try await fixture.detach(first, client: firstClient)
            try await fixture.detach(second, client: secondClient)
            await fixture.cleanup()
        } catch {
            await fixture.cleanup()
            throw error
        }
    }

    private struct Pane {
        let sessionID: String
        let pid: Int
        let directory: String
        let attached: Int
    }

    private enum FixtureError: Error { case tmuxUnavailable, invalidOutput, deadline, commandFailed }

    @MainActor
    private final class Fixture {
        let root: URL
        let socketName: String
        let tmux: String
        let shell: URL
        let workspaceID = UUID()
        let commands: any CommandRunning
        var clients: [Process] = []
        var inputPipes: [Pipe] = []

        init() throws {
            guard let tmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                throw FixtureError.tmuxUnavailable
            }
            self.tmux = tmux
            let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            socketName = "uc-ci-" + suffix
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("uc-tmux-integration-" + suffix)
            shell = root.appendingPathComponent("fixture-shell")
            // A private namespace and empty startup environment isolate CI from both the
            // user's tmux configuration and shell rc files. The runner never reads pane text.
            commands = CommandRunner(environment: ["PATH": "/usr/bin:/bin"], bundledBinPath: nil)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try #"""
            #!/bin/sh
            case "${1-}" in -c|-lc|-ilc) exec /bin/sh -c "$2" ;; esac
            exec /bin/sh -i
            """#.write(to: shell, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)
        }

        func binding(name: String) -> UniConnectLocalTmuxBinding {
            UniConnectLocalTmuxBinding(name: name, socketName: socketName)!
        }

        func directory(_ name: String) throws -> URL {
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }

        func canonicalPath(_ path: String) throws -> String {
            // On macOS 15 Foundation can spell this fixture as /var while tmux
            // reports /private/var. Compare existing directories through POSIX,
            // not Foundation's OS-version-dependent URL normalization.
            guard let resolved = path.withCString({ Darwin.realpath($0, nil) }) else {
                throw FixtureError.invalidOutput
            }
            defer { Darwin.free(resolved) }
            return String(cString: resolved)
        }

        func agentCommand(counter: URL) -> String {
            "printf 'started\\n' >> " + TerminalStartupShellQuoting.singleQuoted(counter.path) + "; /bin/sleep 60"
        }

        func launch(
            binding: UniConnectLocalTmuxBinding, directory: String, command: String?, panelID: UUID, generation: UUID
        ) throws -> Process {
            let plan = UniConnectLocalTmuxLaunchPlan(binding: binding, workingDirectory: directory, initialCommand: command)
            let process = Process(), input = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
            process.arguments = ["-q", "/dev/null", "/bin/sh", "-c", plan.startupCommand(tmuxExecutable: tmux)]
            process.environment = [
                "PATH": "/usr/bin:/bin", "SHELL": shell.path, "TERM": "xterm-256color",
                "CMUX_SURFACE_ID": panelID.uuidString, "CMUX_WORKSPACE_ID": workspaceID.uuidString,
                "UNICONNECT_SURFACE_GENERATION": generation.uuidString,
            ]
            process.currentDirectoryURL = root
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            clients.append(process)
            inputPipes.append(input) // Keep stdin open until the explicit tmux detach.
            return process
        }

        func command(_ arguments: [String]) async throws -> String {
            guard let output = await commands.runStandardOutput(
                directory: root.path, executable: tmux, arguments: ["-L", socketName] + arguments, timeout: 2
            ) else { throw FixtureError.commandFailed }
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func pane(_ binding: UniConnectLocalTmuxBinding) async throws -> Pane {
            let raw = try await command([
                "display-message", "-p", "-t", "=" + binding.name + ":",
                "#{session_id}\t#{pane_pid}\t#{pane_current_path}\t#{session_attached}",
            ])
            let fields = raw.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 4, let pid = Int(fields[1]), pid > 1, let attached = Int(fields[3]) else {
                throw FixtureError.invalidOutput
            }
            return Pane(sessionID: String(fields[0]), pid: pid, directory: String(fields[2]), attached: attached)
        }

        func attachedPane(_ binding: UniConnectLocalTmuxBinding) async throws -> Pane {
            let deadline = ContinuousClock.now + .seconds(8)
            while ContinuousClock.now < deadline {
                if let pane = try? await pane(binding), pane.attached > 0 { return pane }
                try await Task.sleep(for: .milliseconds(40))
            }
            throw FixtureError.deadline
        }

        func environment(_ key: String, _ binding: UniConnectLocalTmuxBinding) async throws -> String {
            let output = try await command(["show-environment", "-t", "=" + binding.name, key])
            guard output.hasPrefix(key + "=") else { throw FixtureError.invalidOutput }
            return String(output.dropFirst(key.count + 1))
        }

        func launchCount(_ counter: URL) throws -> Int {
            try String(contentsOf: counter, encoding: .utf8).split(separator: "\n").count
        }

        func waitForLaunchCount(_ counter: URL, expected: Int) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                if (try? launchCount(counter)) == expected { return }
                try await Task.sleep(for: .milliseconds(40))
            }
            throw FixtureError.deadline
        }

        func detach(_ binding: UniConnectLocalTmuxBinding, client: Process) async throws {
            _ = try await command(["detach-client", "-s", "=" + binding.name])
            let deadline = ContinuousClock.now + .seconds(5)
            while client.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(40)) }
            guard !client.isRunning else { throw FixtureError.deadline }
            #expect(client.terminationStatus == 0)
        }

        func cleanup() async {
            // Only this fixture generated the socket name. Never run kill-server without -L.
            _ = await commands.run(
                directory: root.path, executable: tmux, arguments: ["-L", socketName, "kill-server"], timeout: 2
            )
            for input in inputPipes { try? input.fileHandleForWriting.close() }
            for client in clients where client.isRunning { client.terminate() }
            let deadline = ContinuousClock.now + .seconds(1)
            while clients.contains(where: \.isRunning), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            for client in clients where client.isRunning { _ = Darwin.kill(client.processIdentifier, SIGKILL) }
            try? FileManager.default.removeItem(at: root)
        }
    }
}
