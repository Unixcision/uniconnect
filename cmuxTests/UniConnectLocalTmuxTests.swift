import CmuxProcess
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Host-local durable tmux windows")
struct UniConnectLocalTmuxTests {
    @Test("Stable window identity is independent of agent selection and isolates tagged apps")
    func stableIdentityAndTagIsolation() throws {
        let id = UUID()
        let release = UniConnectLocalTmuxBinding.newWindow(panelID: id, bundleIdentifier: "com.unixcision.uniconnect")
        let debug = UniConnectLocalTmuxBinding.newWindow(panelID: id, bundleIdentifier: "com.unixcision.uniconnect.debug.test")
        #expect(release.name == "uc-" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        #expect(release.socketName == "uniconnect-local")
        #expect(release.name == debug.name)
        #expect(release.socketName != debug.socketName)
        #expect(debug == .newWindow(panelID: id, bundleIdentifier: "com.unixcision.uniconnect.debug.test"))
        #expect(try JSONDecoder().decode(UniConnectLocalTmuxBinding.self, from: JSONEncoder().encode(release)) == release)
        for name in ["", "=other", "../other", "work:1", "work.1", "-bad", "a;touch /tmp/bad", "x\ny"] {
            #expect(UniConnectLocalTmuxBinding(name: name, socketName: "uniconnect-local") == nil)
        }
    }

    @Test("Reattaching never reinjects the initial agent and retains the original cwd and pane environment")
    func attachPreservesInitialAgentAndCWD() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let firstDirectory = fixture.root.appendingPathComponent("project 'one'", isDirectory: true)
        let secondDirectory = fixture.root.appendingPathComponent("project two", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let binding = try #require(UniConnectLocalTmuxBinding(name: "window-one", socketName: "test-local"))
        let first = UniConnectLocalTmuxLaunchPlan(
            binding: binding, workingDirectory: firstDirectory.path,
            initialCommand: #"printf 'original-agent\n' >> "$UC_TEST_ROOT/agents""#
        )
        let second = UniConnectLocalTmuxLaunchPlan(
            binding: binding, workingDirectory: secondDirectory.path,
            initialCommand: #"printf 'duplicate-agent\n' >> "$UC_TEST_ROOT/agents""#
        )
        #expect(try fixture.run(first) == 0)
        #expect(try fixture.run(second) == 0)
        #expect(try fixture.read("agents") == "original-agent\n")
        #expect(try fixture.read("cwd") == firstDirectory.path + "\n")
        #expect(try fixture.read("context") == fixture.panelID.uuidString + "\n")
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("fallback").path))
    }

    @Test("Ghostty's Darwin login wrapper starts the local session and reattaches without rerunning its command")
    func ghosttyDarwinLoginWrapperLaunchesAndReattaches() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let directory = fixture.root.appendingPathComponent("project 'quoted'", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let binding = try #require(UniConnectLocalTmuxBinding(name: "window-darwin", socketName: "test-local"))
        let first = UniConnectLocalTmuxLaunchPlan(
            binding: binding, workingDirectory: directory.path,
            initialCommand: #"printf 'initial-command\n' >> "$UC_TEST_ROOT/agents""#
        )
        let restored = UniConnectLocalTmuxLaunchPlan(
            binding: binding, workingDirectory: fixture.root.path,
            initialCommand: #"printf 'must-not-run-again\n' >> "$UC_TEST_ROOT/agents""#
        )
        // Exec.zig wraps embedded shell commands in `exec -l <command>` on Darwin.
        // A plain `/bin/sh -c` fixture misses an accidental second outer `exec`.
        try #require(fixture.run(first, darwinLoginWrapper: true) == 0)
        #expect(try fixture.run(restored, darwinLoginWrapper: true) == 0)
        #expect(try fixture.read("agents") == "initial-command\n")
        #expect(try fixture.read("cwd") == directory.path + "\n")
        #expect(try fixture.read("context") == fixture.panelID.uuidString + "\n")
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("fallback").path))
    }

    @Test("Missing tmux or failed creation gives a recovery shell without starting an agent")
    func unavailableTmuxDoesNotStartAgent() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let binding = try #require(UniConnectLocalTmuxBinding(name: "window-one", socketName: "test-local"))
        let plan = UniConnectLocalTmuxLaunchPlan(
            binding: binding, workingDirectory: fixture.root.path,
            initialCommand: #"printf 'must-not-run\n' >> "$UC_TEST_ROOT/agents""#
        )
        #expect(try fixture.run(plan, executable: fixture.root.appendingPathComponent("missing-tmux").path) == 0)
        #expect(try fixture.run(plan, failCreation: true) == 0)
        #expect(try fixture.read("fallback") == "shell\nshell\n")
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("agents").path))
    }

    @Test("A deleted folder attaches only the exact saved session and never creates a replacement agent")
    func missingDirectoryUsesExactAttachment() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let binding = try #require(UniConnectLocalTmuxBinding(name: "window-one", socketName: "test-local"))
        #expect(try fixture.run(.init(binding: binding, workingDirectory: fixture.root.path, initialCommand: nil)) == 0)
        let missing = fixture.root.appendingPathComponent("deleted").path
        #expect(try fixture.run(.init(binding: binding, workingDirectory: missing, initialCommand: "exit 91")) == 0)
        #expect(try fixture.read("attached") == "=window-one\n")
        let prefix = try #require(UniConnectLocalTmuxBinding(name: "window", socketName: "test-local"))
        #expect(try fixture.run(.init(binding: prefix, workingDirectory: missing, initialCommand: "exit 92")) == 0)
        #expect(try fixture.read("fallback") == "shell\n")
    }

    @Test("A surviving pane can verify its old hook generation only for its original CMUX owner")
    func verifiesExistingPaneGeneration() async throws {
        let workspace = UUID(), panel = UUID(), generation = UUID()
        let binding = try #require(UniConnectLocalTmuxBinding(name: "window-one", socketName: "test-local"))
        let commands = InspectionCommands(outputs: ["$1\t%2\t123\t0\n", "$1\t%2\t123\t0\n"])
        let inspector = UniConnectLocalTmuxService(commands: commands, processEnvironment: { pid in
            guard pid == 123 else { return nil }
            return ["CMUX_WORKSPACE_ID": workspace.uuidString, "CMUX_SURFACE_ID": panel.uuidString,
                    "UNICONNECT_SURFACE_GENERATION": generation.uuidString]
        })
        #expect(await inspector.generation(for: binding, workspaceID: workspace, panelID: panel) == generation)
        #expect(await commands.targets() == ["=window-one:", "=window-one:"])
    }

    @Test("A changed pane or foreign owner cannot remap old hook events")
    func rejectsReplacedAndForeignPanes() async throws {
        let workspace = UUID(), panel = UUID(), generation = UUID()
        let binding = try #require(UniConnectLocalTmuxBinding(name: "window-one", socketName: "test-local"))
        let changed = UniConnectLocalTmuxService(
            commands: InspectionCommands(outputs: ["$1\t%2\t123\t0\n", "$1\t%3\t124\t0\n"]),
            processEnvironment: { _ in
                ["CMUX_WORKSPACE_ID": workspace.uuidString, "CMUX_SURFACE_ID": panel.uuidString,
                 "UNICONNECT_SURFACE_GENERATION": generation.uuidString]
            }
        )
        #expect(await changed.generation(for: binding, workspaceID: workspace, panelID: panel) == nil)
        let foreign = UniConnectLocalTmuxService(
            commands: InspectionCommands(outputs: ["$1\t%2\t123\t0\n"]),
            processEnvironment: { _ in
                ["CMUX_WORKSPACE_ID": workspace.uuidString, "CMUX_SURFACE_ID": UUID().uuidString,
                 "UNICONNECT_SURFACE_GENERATION": generation.uuidString]
            }
        )
        #expect(await foreign.generation(for: binding, workspaceID: workspace, panelID: panel) == nil)
    }

    private actor InspectionCommands: CommandRunning {
        var outputs: [String]
        var requests: [[String]] = []
        init(outputs: [String]) { self.outputs = outputs }
        func run(directory: String, executable: String, arguments: [String], timeout: TimeInterval?) async -> CommandResult {
            requests.append(arguments)
            return CommandResult(stdout: outputs.isEmpty ? nil : outputs.removeFirst(), stderr: nil,
                                 exitStatus: 0, timedOut: false, executionError: nil)
        }
        func targets() -> [String] {
            requests.compactMap { args in args.firstIndex(of: "-t").map { args[$0 + 1] } }
        }
    }

    private struct Fixture {
        let root: URL
        let panelID = UUID()
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("uc-local-tmux-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let shell = #"""
            #!/bin/sh
            if [ "${1-}" = -ilc ]; then exec /bin/sh -c "$2"; fi
            if [ -z "${TMUX-}" ]; then printf 'shell\n' >> "$UC_TEST_ROOT/fallback"; fi
            exit 0
            """#
            let tmux = #"""
            #!/bin/sh
            [ "$1" = -f ] || exit 81
            shift 2
            [ "$1" = -L ] || exit 82
            shift 2
            action=$1; shift
            if [ "$action" = set-option ]; then
                [ "$1" = -g ] && [ "$2" = history-limit ] && [ "$3" = 50000 ] && [ "$4" = ';' ] || exit 88
                shift 4
                action=$1; shift
            fi
            if [ "$action" = attach-session ]; then
                [ "$1" = -t ] || exit 83
                printf '%s\n' "$2" >> "$UC_TEST_ROOT/attached"
                test -d "$UC_TEST_ROOT/session-${2#=}"; exit $?
            fi
            [ "$action" = new-session ] || exit 84
            [ "$1" = -A ] || exit 85
            shift
            [ "$1" = -s ] || exit 86
            name=$2; shift 2
            while [ "$1" = -e ]; do export "$2"; shift 2; done
            [ "${UC_TEST_FAIL-}" != 1 ] || exit 87
            if mkdir "$UC_TEST_ROOT/session-$name" 2>/dev/null; then
                printf '%s\n' "$PWD" >> "$UC_TEST_ROOT/cwd"
                printf '%s\n' "$CMUX_SURFACE_ID" >> "$UC_TEST_ROOT/context"
                export TMUX=fixture-server
                /bin/sh -c "$1"
            fi
            exit 0
            """#
            for (name, content) in [("shell", shell), ("tmux", tmux)] {
                let path = root.appendingPathComponent(name)
                try content.write(to: path, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
            }
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func read(_ name: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
        }
        func run(
            _ plan: UniConnectLocalTmuxLaunchPlan,
            executable: String? = nil,
            failCreation: Bool = false,
            darwinLoginWrapper: Bool = false
        ) throws -> Int32 {
            let process = Process()
            let command = plan.startupCommand(tmuxExecutable: executable ?? root.appendingPathComponent("tmux").path)
            process.executableURL = URL(fileURLWithPath: darwinLoginWrapper ? "/bin/bash" : "/bin/sh")
            process.arguments = darwinLoginWrapper
                ? ["--noprofile", "--norc", "-c", "exec -l " + command]
                : ["-c", command]
            process.environment = [
                "HOME": root.path, "PATH": "/usr/bin:/bin", "SHELL": root.appendingPathComponent("shell").path,
                "UC_TEST_ROOT": root.path, "UC_TEST_FAIL": failCreation ? "1" : "0",
                "CMUX_SURFACE_ID": panelID.uuidString,
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
    }
}
