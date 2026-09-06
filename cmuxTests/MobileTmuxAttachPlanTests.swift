import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Independent mobile tmux attachment commands")
struct MobileTmuxAttachPlanTests {
    @Test("A supported client links the exact existing window into its own presentation session", arguments: ["3.2", "3.3a", "3.6a", "3.7c"])
    func attachesExistingSession(version: String) throws {
        let fixture = try CommandFixture()
        defer { fixture.remove() }
        #expect(try fixture.run(clientVersion: version, serverVersion: version) == 0)
        let auxiliary = try fixture.read("created").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(auxiliary.hasPrefix("uc-mobile-"))
        #expect(try fixture.read("attached") == "-E\n-f\nignore-size,active-pane\n-t\n=\(auxiliary)\n")
        #expect(try fixture.read("linked") == "$7:@11\n")
        #expect(try fixture.read("calls") == "-V\nhas-session\ndisplay-message\ndisplay-message\nnew-session\nset-option\nset-option\nlink-window\nattach-session\nselect-pane\nselect-pane\n")
        #expect(!fixture.exists("unexpected"))
    }

    @Test("An older, unknown or future server is refused before attachment", arguments: ["3.1c", "2.9", "3.8", "4.0", "next-3.7", "3.7-dev", "3.70"])
    func refusesUnsupportedServer(version: String) throws {
        let fixture = try CommandFixture()
        defer { fixture.remove() }
        #expect(try fixture.run(clientVersion: "3.7c", serverVersion: version) == 78)
        #expect(!fixture.exists("attached"))
        #expect(!fixture.exists("unexpected"))
    }

    @Test("An unsupported executable is refused before contacting any server", arguments: ["3.1c", "3.8", "next-3.7", "3.7-dev"])
    func refusesUnsupportedExecutable(version: String) throws {
        let fixture = try CommandFixture()
        defer { fixture.remove() }
        #expect(try fixture.run(clientVersion: version) == 78)
        #expect(try fixture.read("calls") == "-V\n")
        #expect(!fixture.exists("attached"))
    }

    @Test("A missing saved session is never recreated or replaced with a shell")
    func refusesMissingSession() throws {
        let fixture = try CommandFixture()
        defer { fixture.remove() }
        #expect(try fixture.run(sessionExists: false) == 66)
        #expect(try fixture.read("calls") == "-V\nhas-session\n")
        #expect(!fixture.exists("attached"))
        #expect(!fixture.exists("unexpected"))
    }

    @Test("A disappeared target cannot fall back to another session's displayed pane")
    func refusesChangedSourceContext() throws {
        let fixture = try CommandFixture()
        defer { fixture.remove() }
        #expect(try fixture.run(sourceSessionName: "another-session") == 66)
        #expect(!fixture.exists("created"))
        #expect(!fixture.exists("attached"))
    }

    @Test("Unvalidated shell, missing endpoint and nonexact SSH names cannot become attachments")
    func refusesUnsafeSSHCommands() throws {
        let target = try #require(UniConnectSSHEffectiveTarget(user: "root", host: "example.com", port: 2222))
        for command in ["ssh root@example.com; touch /tmp/forbidden", "ssh root@example.com tmux new-session", "$(touch /tmp/forbidden)"] {
            #expect(throws: MobileTmuxAttachError.invalidSSHCredential) {
                try MobileTmuxAttachPlan.sshCommand(
                    record: .init(connectCommand: command, effectiveTarget: target), session: "owned"
                )
            }
        }
        #expect(throws: MobileTmuxAttachError.invalidSSHCredential) {
            try MobileTmuxAttachPlan.sshCommand(
                record: .init(connectCommand: "ssh root@example.com", effectiveTarget: nil), session: "owned"
            )
        }
        for session in ["", "owned:other", "owned.other", "=owned", "owned;new-session"] {
            #expect(throws: MobileTmuxAttachError.invalidSSHCredential) {
                try MobileTmuxAttachPlan.sshCommand(
                    record: .init(connectCommand: "ssh root@example.com", effectiveTarget: target), session: session
                )
            }
        }
    }

    /// The fixture rejects mutations of original sessions and checks each owned queue target.
    private struct CommandFixture {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("MobileTmuxAttach-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let script = #"""
            #!/bin/sh
            if [ -n "${TMUX-}" ]; then touch "$UC_MOBILE_TEST_ROOT/unexpected"; exit 91; fi
            if [ "$1" = '-V' ]; then
                printf '%s\n' '-V' >> "$UC_MOBILE_TEST_ROOT/calls"
                printf 'tmux %s\n' "$UC_MOBILE_TEST_CLIENT_VERSION"
                exit 0
            fi
            if [ "$1" != '-N' ] || [ "$2" != '-L' ] || [ "$3" != 'fixture-socket' ]; then
                touch "$UC_MOBILE_TEST_ROOT/unexpected"; exit 92
            fi
            shift 3
            while [ "$#" -gt 0 ]; do
            printf '%s\n' "$1" >> "$UC_MOBILE_TEST_ROOT/calls"
            case "$1" in
                has-session)
                    [ "$2" = '-t' ] && [ "$3" = '=owned-session' ] || exit 93
                    [ "$UC_MOBILE_TEST_SESSION_EXISTS" = '1' ]; exit $?
                    ;;
                display-message)
                    [ "$2" = '-p' ] && [ "$3" = '-t' ] && [ "$4" = '=owned-session:' ] || exit 94
                    case "$5" in
                        '#{version}') printf '%s\n' "$UC_MOBILE_TEST_SERVER_VERSION" ;;
                        '#{session_name}|#{session_id}:#{window_id}.#{pane_id}') printf '%s|%s\n' "$UC_MOBILE_TEST_SOURCE_SESSION" '$7:@11.%13' ;;
                        *) exit 94 ;;
                    esac
                    exit 0
                    ;;
                new-session)
                    [ "$2" = '-d' ] && [ "$3" = '-E' ] && [ "$4" = '-s' ] && [ "$6" = '/bin/sleep' ] && [ "$7" = '60' ] || exit 96
                    auxiliary=$5
                    case "$auxiliary" in uc-mobile-*) ;; *) exit 97 ;; esac
                    printf '%s\n' "$auxiliary" > "$UC_MOBILE_TEST_ROOT/created"
                    shift 7
                    ;;
                set-option)
                    [ "$2" = '-t' ] && [ "$3" = "=$auxiliary:" ] && [ "$5" = 'on' ] || exit 98
                    case "$4" in destroy-unattached|detach-on-destroy) ;; *) exit 98 ;; esac
                    shift 5
                    ;;
                link-window)
                    [ "$2" = '-k' ] && [ "$3" = '-s' ] && [ "$4" = '$7:@11' ] && [ "$5" = '-t' ] && [ "$6" = "=$auxiliary:^" ] || exit 99
                    printf '%s\n' "$4" > "$UC_MOBILE_TEST_ROOT/linked"
                    shift 6
                    ;;
                attach-session)
                    [ "$6" = "=$auxiliary" ] || exit 100
                    printf '%s\n' "$2" "$3" "$4" "$5" "$6" > "$UC_MOBILE_TEST_ROOT/attached"
                    shift 6
                    ;;
                select-pane)
                    [ "$2" = '-t' ] || exit 101
                    case "$3" in "=$auxiliary:.+"|"=$auxiliary:.%13") ;; *) exit 101 ;; esac
                    shift 3
                    ;;
                *) touch "$UC_MOBILE_TEST_ROOT/unexpected"; exit 95 ;;
            esac
            if [ "$#" -gt 0 ]; then [ "$1" = ';' ] || exit 102; shift; fi
            done
            """#
            let executable = root.appendingPathComponent("tmux 'fixture'")
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        func run(
            clientVersion: String = "3.7c", serverVersion: String = "3.7c",
            sessionExists: Bool = true, sourceSessionName: String = "owned-session"
        ) throws -> Int32 {
            let binding = try #require(UniConnectLocalTmuxBinding(name: "owned-session", socketName: "fixture-socket"))
            let command = MobileTmuxAttachPlan.localCommand(
                binding: binding, tmuxExecutable: root.appendingPathComponent("tmux 'fixture'").path
            )
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.environment = [
                "PATH": "/usr/bin:/bin", "TMUX": "/tmp/foreign,1,0",
                "UC_MOBILE_TEST_ROOT": root.path,
                "UC_MOBILE_TEST_CLIENT_VERSION": clientVersion,
                "UC_MOBILE_TEST_SERVER_VERSION": serverVersion,
                "UC_MOBILE_TEST_SESSION_EXISTS": sessionExists ? "1" : "0",
                "UC_MOBILE_TEST_SOURCE_SESSION": sourceSessionName,
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }

        func read(_ name: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
        }
        func exists(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

/// Real desktop model registries require serialization even without activating Ghostty.
@MainActor
@Suite("Exact mobile tmux target resolution", .serialized)
struct MobileTmuxTargetResolverTests {
    @Test("Resolution includes background windows without changing selection or activating Ghostty")
    func resolvesBackgroundWindowWithoutFocus() throws {
        let first = TabManager(initialWorkspaceTitle: "Prueba", autoWelcomeIfNeeded: false)
        let second = TabManager(initialWorkspaceTitle: "Prueba", autoWelcomeIfNeeded: false)
        let workspace = second.addTab(select: false)
        let panelID = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.terminalPanel(for: panelID))
        let binding = try #require(UniConnectLocalTmuxBinding(name: "background", socketName: "fixture"))
        workspace.uniConnectLocalWindowsByPanelId[panelID] = .init(boxRoot: "/tmp", tmuxBinding: binding)
        let selectedFirst = first.selectedTabId, selectedSecond = second.selectedTabId
        let focused = workspace.focusedPanelId
        let surface = panel.surface.surface
        let resolver = MobileTmuxTargetResolver(tabManagers: { [first, second] }, credentialRecord: { _ in nil }, isLocked: { false })

        let plan = try resolver.resolve(workspaceID: workspace.id, surfaceID: panelID)
        try resolver.validate(plan)
        #expect(plan.workspaceID == workspace.id)
        #expect(plan.surfaceID == panelID)
        #expect(first.selectedTabId == selectedFirst)
        #expect(second.selectedTabId == selectedSecond)
        #expect(workspace.focusedPanelId == focused)
        #expect(panel.surface.surface == surface)
    }

    @Test("Lock, missing IDs and legacy PTYs fail without selecting another terminal")
    func rejectsUnavailableTarget() throws {
        let manager = TabManager(initialWorkspaceTitle: "Prueba", autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelId)
        var locked = false
        let resolver = MobileTmuxTargetResolver(tabManagers: { [manager] }, credentialRecord: { _ in nil }, isLocked: { locked })
        workspace.uniConnectLocalWindowsByPanelId.removeValue(forKey: panelID)
        #expect(throws: MobileTmuxAttachError.legacyTerminal) {
            try resolver.resolve(workspaceID: workspace.id, surfaceID: panelID)
        }
        #expect(throws: MobileTmuxAttachError.targetUnavailable) {
            try resolver.resolve(workspaceID: UUID(), surfaceID: panelID)
        }
        #expect(throws: MobileTmuxAttachError.targetUnavailable) {
            try resolver.resolve(workspaceID: workspace.id, surfaceID: UUID())
        }
        locked = true
        #expect(throws: MobileTmuxAttachError.locked) {
            try resolver.resolve(workspaceID: workspace.id, surfaceID: panelID)
        }
    }

    @Test("Local binding replacement invalidates an existing connection")
    func detectsLocalRebinding() throws {
        let manager = TabManager(initialWorkspaceTitle: "Prueba", autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelId)
        let binding = try #require(UniConnectLocalTmuxBinding(name: "owned", socketName: "fixture"))
        let record = UniConnectLocalWindowRecord(boxRoot: "/tmp", tmuxBinding: binding)
        workspace.uniConnectLocalWindowsByPanelId[panelID] = record
        let resolver = MobileTmuxTargetResolver(tabManagers: { [manager] }, credentialRecord: { _ in nil }, isLocked: { false })
        let plan = try resolver.resolve(workspaceID: workspace.id, surfaceID: panelID)
        workspace.uniConnectLocalWindowsByPanelId[panelID] = .init(
            id: record.id, boxRoot: "/tmp",
            tmuxBinding: try #require(UniConnectLocalTmuxBinding(name: "replacement", socketName: "fixture"))
        )
        #expect(throws: MobileTmuxAttachError.targetChanged) { try resolver.validate(plan) }
    }

    @Test("Replacing a panel under the same IDs or beginning its close invalidates the attachment")
    func detectsSurfaceReplacementAndClose() throws {
        let manager = TabManager(initialWorkspaceTitle: "Prueba", autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelId)
        let original = try #require(workspace.terminalPanel(for: panelID))
        workspace.uniConnectLocalWindowsByPanelId[panelID] = .init(
            boxRoot: "/tmp", tmuxBinding: try #require(UniConnectLocalTmuxBinding(name: "owned", socketName: "fixture"))
        )
        let resolver = MobileTmuxTargetResolver(tabManagers: { [manager] }, credentialRecord: { _ in nil }, isLocked: { false })
        let originalPlan = try resolver.resolve(workspaceID: workspace.id, surfaceID: panelID)
        let replacement = TerminalPanel(id: panelID, workspaceId: workspace.id)
        workspace.panels[panelID] = replacement
        defer {
            workspace.panels[panelID] = original
            replacement.surface.teardownSurface()
        }
        let replacementPlan = try resolver.resolve(workspaceID: workspace.id, surfaceID: panelID)
        #expect(replacementPlan.identity.surfaceGeneration != originalPlan.identity.surfaceGeneration)
        #expect(throws: MobileTmuxAttachError.targetChanged) { try resolver.validate(originalPlan) }
        replacement.surface.beginPortalCloseLifecycle(reason: "mobile-attachment-test")
        #expect(throws: MobileTmuxAttachError.targetUnavailable) { try resolver.validate(replacementPlan) }
    }

    @Test("SSH revisions remain stable across reads and invalidate on endpoint or credential replacement")
    func detectsSSHRevisionChange() throws {
        let manager = TabManager(initialWorkspaceTitle: "Prueba", autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelId)
        let credentialID = UUID()
        workspace.uniConnectProfile = .init(kind: .ssh, credentialId: credentialID)
        workspace.uniConnectTmuxSessionsByPanelId[panelID] = "owned"
        let target = try #require(UniConnectSSHEffectiveTarget(user: "root", host: "example.com", port: 2222))
        var record = UniConnectSSHCredentialRecord(connectCommand: "ssh -i /tmp/private-key private-alias", effectiveTarget: target)
        let resolver = MobileTmuxTargetResolver(
            tabManagers: { [manager] }, credentialRecord: { $0 == credentialID ? record : nil }, isLocked: { false }
        )
        let plan = try resolver.resolve(workspaceID: workspace.id, surfaceID: panelID)
        for _ in 0..<8 { try resolver.validate(plan) }
        #expect(!String(describing: plan).contains("private-key"))
        #expect(!String(reflecting: plan).contains("private-alias"))
        record = .init(connectCommand: "ssh -i /tmp/new-key private-alias", effectiveTarget: target)
        #expect(throws: MobileTmuxAttachError.targetChanged) { try resolver.validate(plan) }
        record = .init(
            connectCommand: "ssh -i /tmp/private-key private-alias",
            effectiveTarget: try #require(UniConnectSSHEffectiveTarget(user: "root", host: "other.example.com", port: 2222))
        )
        #expect(throws: MobileTmuxAttachError.targetChanged) { try resolver.validate(plan) }
    }
}
