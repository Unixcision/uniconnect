import CmuxControlSocket
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
@Suite(.serialized)
struct UniConnectLocalTmuxSocketAccessTests {
    @Test("cmuxOnly accepts the registered tmux pane but rejects its sibling and a revoked binding")
    func registeredTmuxClientUsesTheRealSocketGate() async throws {
        let fixture = try Fixture()
        let previousDelegate = AppDelegate.shared
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let previousEnable = ProcessInfo.processInfo.environment["UNICONNECT_TEST_ENABLE"]
        // Build the ordinary model first; no Ghostty view, vault or application launch.
        let manager = TabManager()
        let workspace = try #require(manager.tabs.first)
        let panelID = try #require(workspace.focusedPanelId)
        let generation = try #require(workspace.uniConnectSurfaceGeneration(panelId: panelID))
        let delegate = AppDelegate()
        AppDelegate.shared = delegate
        let windowID = delegate.registerMainWindowContextForTesting(tabManager: manager)
        setenv("UNICONNECT_TEST_ENABLE", "1", 1)
        defer {
            TerminalController.shared.stop()
            delegate.unregisterMainWindowContextForTesting(windowId: windowID)
            AppDelegate.shared = previousDelegate
            TerminalController.shared.setActiveTabManager(previousManager)
            if let previousEnable { setenv("UNICONNECT_TEST_ENABLE", previousEnable, 1) }
            else { unsetenv("UNICONNECT_TEST_ENABLE") }
        }
        do {
            workspace.uniConnectProfile = UniConnectWorkspaceProfile(kind: .local, localRoot: fixture.root.path)
            let binding = try #require(UniConnectLocalTmuxBinding(name: "owned", socketName: fixture.namespace))
            workspace.uniConnectInstallLocalWindowRecord(
                UniConnectLocalWindowRecord(
                    id: panelID, boxRoot: fixture.root.path,
                    workingDirectory: fixture.root.path, tmuxBinding: binding
                ), panelId: panelID
            )
            UniConnectCoordinator.shared.configureLocalTmuxInspector(UniConnectLocalTmuxService(
                commands: CommandRunner(),
                processEnvironment: { CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: $0)?.environment }
            ))
            TerminalController.shared.start(tabManager: manager, socketPath: fixture.socketPath, accessMode: .cmuxOnly)
            try await fixture.waitForFile(URL(fileURLWithPath: fixture.socketPath))

            // Both sessions deliberately carry identical claimed IDs. Only "owned" is
            // registered in the real Workspace; ancestry from the server alone is insufficient.
            for session in ["owned", "foreign"] {
                try await fixture.startClient(
                    session: session, workspaceID: workspace.id, panelID: panelID, generation: generation
                )
            }
            let owned = try await fixture.probe(session: "owned", index: 0)
            let panePID = try await fixture.panePID(session: "owned")
            let transport = SocketTransport()
            #expect(!transport.isProcessDescendant(owned.pid, of: getpid()))
            #expect(transport.isProcessDescendant(owned.pid, of: panePID))
            // This is the red regression: the existing gate returns Access denied even
            // though the exact, still-live pane belongs to the registered Workspace.
            #expect(owned.response == "PONG", "Actual socket response: \(owned.response); error: \(owned.error ?? "none")")

            let foreign = try await fixture.probe(session: "foreign", index: 0)
            #expect(!transport.isProcessDescendant(foreign.pid, of: panePID))
            #expect(foreign.wasDenied)

            workspace.uniConnectInstallLocalWindowRecord(
                UniConnectLocalWindowRecord(id: panelID, boxRoot: fixture.root.path, workingDirectory: fixture.root.path),
                panelId: panelID
            )
            let revoked = try await fixture.probe(session: "owned", index: 1)
            #expect(revoked.pid == owned.pid)
            #expect(try await fixture.panePID(session: "owned") == panePID)
            #expect(revoked.wasDenied)
            TerminalController.shared.stop()
            await fixture.cleanup()
        } catch {
            TerminalController.shared.stop()
            await fixture.cleanup()
            throw error
        }
    }

    private struct Reply: Decodable {
        let pid: pid_t
        let response: String
        let error: String?

        var wasDenied: Bool {
            response.hasPrefix("ERROR:") || ["BrokenPipeError", "ConnectionResetError"].contains(error ?? "")
        }
    }

    private enum FixtureError: Error { case missingTmux, temporaryDirectory, commandFailed, deadline, invalidPID }

    @MainActor
    private final class Fixture {
        let root: URL
        let namespace: String
        let tmux: String
        let commands: any CommandRunning
        var socketPath: String { root.appendingPathComponent("control.sock").path }

        init() throws {
            guard let tmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                throw FixtureError.missingTmux
            }
            self.tmux = tmux
            var template = Array("/tmp/uc-socket-gate.XXXXXX".utf8CString)
            guard let directory = mkdtemp(&template) else { throw FixtureError.temporaryDirectory }
            root = URL(fileURLWithPath: String(cString: directory), isDirectory: true)
            namespace = "uc-ci-gate-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            commands = CommandRunner(environment: ["PATH": "/usr/bin:/bin", "SHELL": "/bin/sh"], bundledBinPath: nil)
            let client = #"""
            import json, os, pathlib, socket, sys, time
            root, session, endpoint = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
            deadline = time.monotonic() + 45
            for index in range(2):
                trigger = root / (session + '-go-' + str(index))
                while not trigger.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                if not trigger.exists():
                    sys.exit(3)
                result = {'pid': os.getpid(), 'response': '', 'error': None}
                try:
                    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                        connection.settimeout(8)
                        connection.connect(endpoint)
                        connection.sendall(b'ping\n')
                        reply = b''
                        while b'\n' not in reply and len(reply) < 4096:
                            chunk = connection.recv(4096 - len(reply))
                            if not chunk:
                                break
                            reply += chunk
                        result['response'] = reply.decode('utf-8', errors='replace').strip()
                except OSError as error:
                    result['error'] = type(error).__name__
                destination = root / (session + '-reply-' + str(index))
                temporary = destination.with_suffix('.tmp')
                temporary.write_text(json.dumps(result))
                temporary.replace(destination)
            # Keep the peer PID alive for the ancestry/revocation assertions.
            while time.monotonic() < deadline:
                time.sleep(0.05)
            """#
            try client.write(to: root.appendingPathComponent("client.py"), atomically: true, encoding: .utf8)
        }

        func startClient(session: String, workspaceID: UUID, panelID: UUID, generation: UUID) async throws {
            let quote = TerminalStartupShellQuoting.singleQuoted
            let command = ["/usr/bin/python3", quote(root.appendingPathComponent("client.py").path),
                           quote(root.path), quote(session), quote(socketPath)].joined(separator: " ") + "; /bin/sleep 45"
            _ = try await run([
                "-f", "/dev/null", "new-session", "-d", "-s", session,
                "-e", "CMUX_WORKSPACE_ID=\(workspaceID.uuidString)",
                "-e", "CMUX_SURFACE_ID=\(panelID.uuidString)",
                "-e", "UNICONNECT_SURFACE_GENERATION=\(generation.uuidString)", command,
            ])
        }

        func probe(session: String, index: Int) async throws -> Reply {
            let reply = root.appendingPathComponent("\(session)-reply-\(index)")
            try Data().write(to: root.appendingPathComponent("\(session)-go-\(index)"))
            try await waitForFile(reply)
            return try JSONDecoder().decode(Reply.self, from: Data(contentsOf: reply))
        }

        func panePID(session: String) async throws -> pid_t {
            let output = try await run(["display-message", "-p", "-t", "=" + session + ":", "#{pane_pid}"])
            guard let pid = pid_t(output), pid > 1 else { throw FixtureError.invalidPID }
            return pid
        }

        func waitForFile(_ file: URL) async throws {
            let deadline = ContinuousClock.now + .seconds(12)
            while ContinuousClock.now < deadline {
                if FileManager.default.fileExists(atPath: file.path) { return }
                try await Task.sleep(for: .milliseconds(30))
            }
            throw FixtureError.deadline
        }

        private func run(_ arguments: [String]) async throws -> String {
            guard let output = await commands.runStandardOutput(
                directory: root.path, executable: tmux, arguments: ["-L", namespace] + arguments, timeout: 3
            ) else { throw FixtureError.commandFailed }
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func cleanup() async {
            // Only the random server created by this fixture, never the default or app namespace.
            _ = await commands.run(directory: root.path, executable: tmux, arguments: ["-L", namespace, "kill-server"], timeout: 3)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
