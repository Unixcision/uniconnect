import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Mobile tmux attachment isolation", .timeLimit(.minutes(1)))
struct MobileTmuxPTYIntegrationTests {
    @Test("Mobile geometry, window and pane selection stay independent of the desktop client")
    func realTmuxClientIsolation() async throws {
        let configured = ProcessInfo.processInfo.environment["UNICONNECT_TEST_TMUX_EXECUTABLE"]
        let executable = try #require(
            ([configured].compactMap { $0 } + ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"])
                .first { FileManager.default.isExecutableFile(atPath: $0) },
            "This integration test requires tmux in the isolated CI runner."
        )
        // Darwin's sockaddr_un path is short; the runner's per-user temporary
        // directory plus a second UUID can exceed it before tmux even starts.
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("ucmt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        // TMUX_TMPDIR is already unique per fixture, including its socket namespace.
        let binding = try #require(UniConnectLocalTmuxBinding(name: "fixture", socketName: "mobile"))
        let environment = [
            "HOME": directory.path, "TMPDIR": directory.path, "TMUX_TMPDIR": directory.path,
            "PATH": "/usr/bin:/bin", "SHELL": "/bin/sh", "TERM": "xterm-256color",
        ]
        let desktop = MobilePTYProcess(environment: environment)
        let mobile = MobilePTYProcess(environment: environment)
        var desktopOutput: Task<Void, Never>?
        var mobileOutput: Task<Void, Never>?
        do {
            _ = try await tmux(executable, binding, environment, ["-f", "/dev/null", "new-session", "-d", "-s", binding.name, "-x", "200", "-y", "49", "exec /bin/cat"])
            _ = try await tmux(executable, binding, environment, ["split-window", "-h", "-t", "=fixture:", "exec /bin/cat"])
            _ = try await tmux(executable, binding, environment, ["select-pane", "-t", "=fixture:.0"])
            let sourceWindow = try await tmux(executable, binding, environment, ["display-message", "-p", "-t", "=fixture:", "#{window_id}"])
            let otherWindow = try await tmux(executable, binding, environment, ["new-window", "-d", "-P", "-F", "#{window_id}", "-t", "=fixture:", "exec /bin/cat"])
            _ = try await tmux(executable, binding, environment, ["set-option", "-g", "status", "off"])
            _ = try await tmux(executable, binding, environment, ["set-option", "-g", "mouse", "off"])
            _ = try await tmux(executable, binding, environment, ["set-option", "-g", "base-index", "4"])
            let accidentalLaunch = directory.appendingPathComponent("unexpected-default-command")
            _ = try await tmux(executable, binding, environment, ["set-option", "-g", "default-command", "printf unexpected > " + UniConnectSSH.singleQuoted(accidentalLaunch.path)])
            let originalOptions = try await tmux(executable, binding, environment, ["show-options", "-t", "=fixture:"])
            _ = try await tmux(executable, binding, environment, ["set-hook", "-g", "client-attached", "wait-for -S desktop-attached"])
            let desktopEvents = try await desktop.start(
                command: "exec " + UniConnectSSH.singleQuoted(executable) + " -N -L " + UniConnectSSH.singleQuoted(binding.socketName) + " attach-session -t '=fixture'",
                columns: 200, rows: 49
            )
            desktopOutput = drain(desktopEvents)
            _ = try await tmux(executable, binding, environment, ["wait-for", "desktop-attached"])
            let before = try await tmux(executable, binding, environment, ["display-message", "-p", "-t", "=fixture:", "#{window_width} #{window_height} #{pane_id}"])
            let panesBefore = try await tmux(executable, binding, environment, ["list-panes", "-t", "=fixture:", "-F", "#{pane_id} #{pane_active}"])
            #expect(before.hasPrefix("200 49 "))
            _ = try await tmux(executable, binding, environment, ["set-hook", "-g", "client-attached", "wait-for -S mobile-attached"])
            let mobileEvents = try await mobile.start(
                command: MobileTmuxAttachPlan.localCommand(binding: binding, tmuxExecutable: executable),
                columns: 40, rows: 12
            )
            mobileOutput = drain(mobileEvents)
            _ = try await tmux(executable, binding, environment, ["wait-for", "mobile-attached"])
            let afterAttach = try await tmux(executable, binding, environment, ["display-message", "-p", "-t", "=fixture:", "#{window_width} #{window_height} #{pane_id}"])
            #expect(afterAttach == before)

            _ = try await tmux(executable, binding, environment, ["set-hook", "-g", "client-resized", "wait-for -S mobile-resized"])
            try await mobile.resize(columns: 300, rows: 100)
            _ = try await tmux(executable, binding, environment, ["wait-for", "mobile-resized"])
            let afterResize = try await tmux(executable, binding, environment, ["display-message", "-p", "-t", "=fixture:", "#{window_width} #{window_height} #{pane_id}"])
            #expect(afterResize == before)

            let clients = try await tmux(executable, binding, environment, ["list-clients", "-F", "#{client_tty}|#{client_flags}|#{client_session}"])
            let mobileFields = try #require(clients.split(separator: "\n").first { $0.contains("ignore-size") }).split(separator: "|")
            let mobileTTY = String(mobileFields[0])
            let auxiliary = String(mobileFields[2])
            #expect(auxiliary.hasPrefix("uc-mobile-"))
            #expect(auxiliary != binding.name)
            #expect(try await tmux(executable, binding, environment, ["show-options", "-v", "-t", "=" + auxiliary + ":", "mouse"]) == "on")
            #expect(try await tmux(executable, binding, environment, ["show-options", "-gv", "mouse"]) == "off")
            #expect(try await tmux(executable, binding, environment, ["show-options", "-Av", "-t", "=fixture:", "mouse"]) == "off")
            // tmux has no client_active_pane format. A binding runs with the
            // receiving client's pane context; an external display-message -c
            // does not select that client's private active pane as its target.
            _ = try await tmux(executable, binding, environment, [
                "bind-key", "-n", "C-g",
                "set-option -gF @mobile-test-observed '#{client_tty}|#{session_name}|#{window_id}|#{pane_id}'; wait-for -S mobile-probed",
            ])
            let sourcePaneIDs = Set(panesBefore.split(separator: "\n").compactMap { $0.split(separator: " ").first.map(String.init) })
            func observeMobilePane() async throws -> String {
                // One ordinary key avoids terminal-specific function-key maps.
                try await mobile.write(Data([0x07]))
                _ = try await tmux(executable, binding, environment, ["wait-for", "mobile-probed"])
                let observation = try await tmux(executable, binding, environment, ["show-options", "-gv", "@mobile-test-observed"])
                let fields = observation.split(separator: "|", omittingEmptySubsequences: false)
                try #require(fields.count == 4 && fields.allSatisfy { !$0.isEmpty })
                #expect(String(fields[0]) == mobileTTY)
                #expect(String(fields[1]) == auxiliary)
                #expect(String(fields[2]) == sourceWindow)
                let pane = String(fields[3])
                try #require(sourcePaneIDs.contains(pane))
                return pane
            }
            let mobileBefore = try await observeMobilePane()
            #expect(mobileBefore == before.split(separator: " ").last.map(String.init))
            _ = try await tmux(executable, binding, environment, ["set-hook", "-g", "after-select-pane", "wait-for -S mobile-selected"])
            try await mobile.write(Data([0x02, 0x6f]))
            _ = try await tmux(executable, binding, environment, ["wait-for", "mobile-selected"])
            let mobileAfter = try await observeMobilePane()
            let panesAfter = try await tmux(executable, binding, environment, ["list-panes", "-t", "=fixture:", "-F", "#{pane_id} #{pane_active}"])
            #expect(mobileAfter != mobileBefore)
            #expect(panesAfter == panesBefore)

            _ = try await tmux(executable, binding, environment, ["select-window", "-t", "=fixture:" + otherWindow])
            let desktopWindowAfter = try await tmux(executable, binding, environment, ["display-message", "-p", "-t", "=fixture:", "#{window_id}"])
            let mobileWindowAfter = try await tmux(executable, binding, environment, ["display-message", "-p", "-t", "=" + auxiliary + ":", "#{window_id}"])
            let mobilePaneAfterSwitch = try await observeMobilePane()
            #expect(desktopWindowAfter == otherWindow)
            #expect(mobileWindowAfter == sourceWindow)
            #expect(mobilePaneAfterSwitch == mobileAfter)
            #expect(try await tmux(executable, binding, environment, ["show-options", "-t", "=fixture:"]) == originalOptions)
            #expect(!FileManager.default.fileExists(atPath: accidentalLaunch.path))

            _ = try await tmux(executable, binding, environment, ["set-hook", "-g", "client-detached", "wait-for -S mobile-detached"])
            await mobile.close()
            _ = try await tmux(executable, binding, environment, ["wait-for", "mobile-detached"])
            _ = try await tmux(executable, binding, environment, ["has-session", "-t", "=fixture"])
            let remaining = try await tmux(executable, binding, environment, ["list-clients", "-F", "#{client_tty}"])
            #expect(remaining.split(separator: "\n").count == 1)
            let sessions = try await tmux(executable, binding, environment, ["list-sessions", "-F", "#{session_name}"])
            #expect(sessions == binding.name)
            // Exercise the production geometry-enabled command, not just synthetic
            // markers. No hooks are installed on the original session or globally.
            let metadataClient = MobilePTYProcess(environment: environment)
            let nonce = UUID()
            var decoder = MobileTmuxOutputDecoder(nonce: nonce)
            var geometry: MobileTmuxGeometry?
            do {
                let metadataEvents = try await metadataClient.start(
                    command: MobileTmuxAttachPlan.localCommand(
                        binding: binding, tmuxExecutable: executable, geometryNonce: nonce
                    ), columns: 300, rows: 100
                )
                metadata: for await output in metadataEvents {
                    for decoded in decoder.decode(output) {
                        if case .geometry(let value) = decoded {
                            geometry = value
                            break metadata
                        }
                    }
                }
                await metadataClient.close()
            } catch {
                await metadataClient.close()
                throw error
            }
            #expect(geometry?.columns == 200)
            #expect(geometry?.rows == 49)
            #expect(geometry?.statusRows == 0)
        } catch {
            await mobile.close()
            await desktop.close()
            mobileOutput?.cancel()
            desktopOutput?.cancel()
            _ = try? await tmux(executable, binding, environment, ["kill-server"])
            throw error
        }
        await mobile.close()
        await desktop.close()
        mobileOutput?.cancel()
        desktopOutput?.cancel()
        _ = try? await tmux(executable, binding, environment, ["kill-server"])
    }

    private func drain(_ stream: AsyncStream<MobilePTYOutput>) -> Task<Void, Never> {
        Task {
            for await event in stream {
                if case .failed(let error) = event { Issue.record("Unexpected PTY failure: \(error)") }
            }
        }
    }

    private func tmux(
        _ executable: String, _ binding: UniConnectLocalTmuxBinding,
        _ environment: [String: String], _ arguments: [String]
    ) async throws -> String {
        let runner = UniConnectControlledProcessRunner(maximumOutputBytes: 16 * 1024)
        let result = try await runner.run(
            executable: executable, arguments: ["-L", binding.socketName] + arguments,
            environment: environment, timeout: .seconds(10)
        )
        try #require(result.terminationStatus == 0, "tmux fixture command failed: \(String(decoding: result.standardError, as: UTF8.self))")
        return String(decoding: result.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
