import Foundation
import CryptoKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class UniConnectRecoveryPersistenceTests: XCTestCase {
    func testStandardPolicyRunsEverySixHoursAndKeepsSevenDaysAtMostTwentyEight() {
        let policy = UniConnectRecoveryBackupPolicy.standard
        XCTAssertEqual(policy.interval, 6 * 60 * 60)
        XCTAssertEqual(policy.retention, 7 * 24 * 60 * 60)
        XCTAssertEqual(policy.maximumCount, 28)
        XCTAssertEqual(policy.maximumBeforeRestoreCount, 7)

        let now = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertTrue(policy.isScheduledBackupDue(lastScheduledAt: nil, now: now))
        XCTAssertFalse(policy.isScheduledBackupDue(lastScheduledAt: now.addingTimeInterval(-21_599), now: now))
        XCTAssertTrue(policy.isScheduledBackupDue(lastScheduledAt: now.addingTimeInterval(-21_600), now: now))

        let dates = (0..<40).map { now.addingTimeInterval(-TimeInterval($0) * 6 * 60 * 60) }
        let retained = policy.retainedIndices(for: dates, now: now)
        XCTAssertEqual(retained.count, 28)
        XCTAssertEqual(retained.max(), 27)

        let datesWithFutureEntry = [now.addingTimeInterval(86_400)] + dates
        let retainedAfterClockRollback = policy.retainedIndices(
            for: datesWithFutureEntry,
            now: now
        )
        XCTAssertFalse(retainedAfterClockRollback.contains(0))
        XCTAssertTrue(retainedAfterClockRollback.contains(1))
        XCTAssertEqual(retainedAfterClockRollback.count, 28)
    }

    func testAtomicWriterUsesPrivatePermissionsAndLeavesNoTemporaryFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-atomic-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("session.json")

        try UniConnectAtomicFileWriter.write(Data("first".utf8), to: fileURL)
        try UniConnectAtomicFileWriter.write(Data("second".utf8), to: fileURL)

        XCTAssertEqual(try Data(contentsOf: fileURL), Data("second".utf8))
        let fileMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber
        ).intValue
        let directoryMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        ).intValue
        XCTAssertEqual(fileMode & 0o777, 0o600)
        XCTAssertEqual(directoryMode & 0o777, 0o700)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(leftovers, ["session.json"])

        XCTAssertEqual(
            try UniConnectAtomicFileWriter.readPrivateFile(at: fileURL),
            Data("second".utf8)
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: fileURL.path
        )
        XCTAssertThrowsError(try UniConnectAtomicFileWriter.readPrivateFile(at: fileURL))
        XCTAssertEqual(
            try UniConnectAtomicFileWriter.readPrivateFile(at: fileURL, repairPermissions: true),
            Data("second".utf8)
        )
        let repairedMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber
        ).intValue
        XCTAssertEqual(repairedMode & 0o777, 0o600)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: fileURL.path
        )

        let symlinkURL = directory.appendingPathComponent("vault-link.uc")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: fileURL)
        XCTAssertThrowsError(try UniConnectAtomicFileWriter.readPrivateFile(at: symlinkURL))
    }

    func testSSHReadableSnapshotContainsOnlyOpaqueCredentialAndRecoveryFields() throws {
        let credentialID = UUID()
        let panelID = UUID()
        let secret = "super-secret-password"
        let terminal = SessionTerminalPanelSnapshot(
            workingDirectory: "/srv/project",
            scrollback: "sshpass -p '\(secret)' ssh root@example.test",
            agent: nil,
            tmuxStartCommand: "ssh -i /Users/me/private.pem root@example.test",
            resumeBinding: SurfaceResumeBindingSnapshot(
                command: "sshpass -p '\(secret)' ssh root@example.test"
            ),
            textBoxDraft: nil,
            wasAgentRunning: true,
            uniConnectTmuxSession: "uc-claude",
            uniConnectClaudeSession: nil
        )
        let snapshot = makeSnapshot(
            workspaceName: "Production",
            workspaceDirectory: "/srv/project",
            panelID: panelID,
            panelName: "API logs",
            terminal: terminal,
            profile: UniConnectWorkspaceProfile(
                kind: .ssh,
                credentialId: credentialID,
                hostLabel: "root@example.test",
                tmuxReady: true
            )
        )

        let data = try SessionPersistenceStore.encodedSnapshotDataForPersistence(snapshot)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains(credentialID.uuidString))
        XCTAssertTrue(text.contains("uc-claude"))
        XCTAssertTrue(text.contains("API logs"))
        XCTAssertFalse(text.contains(secret))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("sshpass"))
        XCTAssertFalse(text.contains("private.pem"))
        XCTAssertFalse(text.contains("ssh -i"))
        let restored = try JSONDecoder().decode(AppSessionSnapshot.self, from: data)
        let restoredWorkspace = try XCTUnwrap(restored.windows.first?.tabManager.workspaces.first)
        let restoredPanel = try XCTUnwrap(restoredWorkspace.panels.first)
        XCTAssertEqual(
            restoredWorkspace.currentDirectory,
            FileManager.default.homeDirectoryForCurrentUser.path
        )
        XCTAssertNil(restoredPanel.directory)
        XCTAssertNil(restoredPanel.terminal?.workingDirectory)
    }

    func testSSHReadableHostLabelIsBoundedAndRejectsControlCharacters() {
        let credentialID = UUID()
        let base = UniConnectWorkspaceProfile(
            kind: .ssh,
            credentialId: credentialID,
            hostLabel: "root@example.test",
            tmuxReady: true
        )
        let valid = SessionPersistenceStore.sanitizedProfileForPersistence(
            base,
            localRootCandidate: nil
        )
        XCTAssertEqual(valid.hostLabel, "root@example.test")
        XCTAssertEqual(valid.credentialId, credentialID)

        var controlled = base
        controlled.hostLabel = "root@example.test\nsshpass -p secret"
        XCTAssertNil(
            SessionPersistenceStore.sanitizedProfileForPersistence(
                controlled,
                localRootCandidate: nil
            ).hostLabel
        )

        var oversized = base
        oversized.hostLabel = String(
            repeating: "h",
            count: SessionPersistenceStore.maximumSSHHostLabelUTF8Bytes + 1
        )
        XCTAssertNil(
            SessionPersistenceStore.sanitizedProfileForPersistence(
                oversized,
                localRootCandidate: nil
            ).hostLabel
        )
    }

    func testLocalReadableSnapshotKeepsIdentityButStripsCapturedAgentSecrets() throws {
        let panelID = UUID()
        let claudeSessionID = UUID().uuidString.lowercased()
        let createdAt = 1_999_000.5
        let lastActivityAt = 1_999_999.75
        let secret = "local-api-token-must-not-reach-readable-recovery"
        let launchCommand = AgentLaunchCommandSnapshot(
            launcher: "/bin/zsh",
            executablePath: "/opt/homebrew/bin/claude",
            arguments: [
                "/opt/homebrew/bin/claude",
                "--dangerously-skip-permissions",
                "--resume",
                claudeSessionID,
                "--api-key",
                secret,
            ],
            workingDirectory: "/Users/test/Projects/Exact Path",
            environment: ["ANTHROPIC_API_KEY": secret, "TERM": "xterm-256color"],
            capturedAt: 1_999_900.25,
            source: "agent-hook"
        )
        let terminal = SessionTerminalPanelSnapshot(
            workingDirectory: "/Users/test/Projects/Exact Path",
            agent: SessionRestorableAgentSnapshot(
                kind: .claude,
                sessionId: claudeSessionID,
                workingDirectory: "/Users/test/Projects/Exact Path",
                launchCommand: launchCommand
            ),
            hibernation: SessionAgentHibernationSnapshot(
                hibernatedAt: 1_999_950,
                lastActivityAt: 1_999_940
            ),
            wasAgentRunning: true,
            uniConnectClaudeSession: claudeSessionID
        )
        let snapshot = makeSnapshot(
            workspaceName: "Local project",
            workspaceDirectory: "/Users/test/Projects/Exact Path",
            panelID: panelID,
            panelName: "Claude review",
            terminal: terminal,
            profile: UniConnectWorkspaceProfile(
                kind: .local,
                importIdentity: UUID(),
                localRoot: "/Users/test/Projects/Exact Path",
                createdAt: createdAt,
                lastActivityAt: lastActivityAt
            )
        )

        let data = try SessionPersistenceStore.encodedSnapshotDataForPersistence(snapshot)
        let restored = try JSONDecoder().decode(AppSessionSnapshot.self, from: data)
        let workspace = try XCTUnwrap(restored.windows.first?.tabManager.workspaces.first)
        let panel = try XCTUnwrap(workspace.panels.first)
        XCTAssertEqual(workspace.customTitle, "Local project")
        XCTAssertEqual(workspace.currentDirectory, "/Users/test/Projects/Exact Path")
        XCTAssertEqual(panel.customTitle, "Claude review")
        XCTAssertEqual(panel.terminal?.workingDirectory, "/Users/test/Projects/Exact Path")
        XCTAssertEqual(panel.terminal?.uniConnectClaudeSession, claudeSessionID)
        XCTAssertEqual(panel.terminal?.wasAgentRunning, true)
        XCTAssertEqual(panel.terminal?.agent?.kind, .claude)
        XCTAssertEqual(panel.terminal?.agent?.sessionId, claudeSessionID)
        XCTAssertEqual(panel.terminal?.agent?.workingDirectory, "/Users/test/Projects/Exact Path")
        XCTAssertEqual(panel.terminal?.agent?.launchCommand?.launcher, nil)
        XCTAssertEqual(panel.terminal?.agent?.launchCommand?.executablePath, "claude")
        XCTAssertEqual(
            panel.terminal?.agent?.launchCommand?.arguments,
            ["claude", "--dangerously-skip-permissions"]
        )
        XCTAssertNil(panel.terminal?.agent?.launchCommand?.environment)
        XCTAssertEqual(panel.terminal?.agent?.launchCommand?.source, "uniconnect-local-history")
        XCTAssertEqual(panel.terminal?.uniConnectLocalWindow?.latestConversation?.sessionID, claudeSessionID)
        XCTAssertEqual(panel.terminal?.uniConnectLocalWindow?.runtimeState, .agent)
        XCTAssertEqual(panel.terminal?.uniConnectLocalWindow?.boxRoot, "/Users/test/Projects/Exact Path")
        XCTAssertEqual(
            panel.terminal?.uniConnectLocalWindow?.workingDirectory,
            "/Users/test/Projects/Exact Path"
        )
        XCTAssertEqual(panel.terminal?.hibernation?.hibernatedAt, 1_999_950)
        XCTAssertEqual(panel.terminal?.hibernation?.lastActivityAt, 1_999_940)
        XCTAssertEqual(workspace.uniConnect?.createdAt, createdAt)
        XCTAssertEqual(workspace.uniConnect?.lastActivityAt, lastActivityAt)
        let readableText = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(readableText.contains(secret))
        XCTAssertFalse(readableText.contains("ANTHROPIC_API_KEY"))
        XCTAssertFalse(readableText.contains("/opt/homebrew/bin/claude"))
        XCTAssertFalse(readableText.contains("--api-key"))
    }

    func testLocalReadableSnapshotRoundTripsDistinctPerWindowWorkingDirectories() throws {
        let root = "/repo"
        let apiID = UUID(uuidString: "52000000-0000-0000-0000-000000000001")!
        let webID = UUID(uuidString: "52000000-0000-0000-0000-000000000002")!
        func panel(id: UUID, name: String, cwd: String) -> SessionPanelSnapshot {
            let record = UniConnectLocalWindowRecord(
                id: id,
                visibleName: name,
                boxRoot: root,
                workingDirectory: cwd,
                createdAt: 1,
                updatedAt: 1
            )
            return SessionPanelSnapshot(
                id: id,
                type: .terminal,
                title: name,
                customTitle: name,
                directory: cwd,
                isPinned: false,
                isManuallyUnread: false,
                gitBranch: nil,
                listeningPorts: [],
                ttyName: nil,
                terminal: SessionTerminalPanelSnapshot(
                    workingDirectory: cwd,
                    uniConnectLocalWindow: record
                ),
                browser: nil,
                markdown: nil,
                filePreview: nil,
                rightSidebarTool: nil,
                project: nil
            )
        }
        var snapshot = makeSnapshot(
            workspaceName: "Repository",
            workspaceDirectory: root,
            panelID: apiID,
            profile: UniConnectWorkspaceProfile(kind: .local, localRoot: root)
        )
        snapshot.windows[0].tabManager.workspaces[0].panels = [
            panel(id: apiID, name: "API", cwd: "/repo/api"),
            panel(id: webID, name: "Web", cwd: "/repo/web"),
        ]
        snapshot.windows[0].tabManager.workspaces[0].layout = .pane(
            SessionPaneLayoutSnapshot(panelIds: [apiID, webID], selectedPanelId: apiID)
        )

        let data = try SessionPersistenceStore.encodedSnapshotDataForPersistence(snapshot)
        let decoded = try JSONDecoder().decode(AppSessionSnapshot.self, from: data)
        let workspace = try XCTUnwrap(decoded.windows.first?.tabManager.workspaces.first)

        XCTAssertEqual(workspace.currentDirectory, root)
        XCTAssertEqual(workspace.panels.map(\.directory), ["/repo/api", "/repo/web"])
        XCTAssertEqual(
            workspace.panels.map { $0.terminal?.workingDirectory },
            ["/repo/api", "/repo/web"]
        )
        XCTAssertEqual(
            workspace.panels.map { $0.terminal?.uniConnectLocalWindow?.workingDirectory },
            ["/repo/api", "/repo/web"]
        )
        XCTAssertTrue(
            workspace.panels.allSatisfy {
                $0.terminal?.uniConnectLocalWindow?.boxRoot == root
            }
        )
    }

    @MainActor
    func testClosedLocalPanelHistoryRebuildsAgentFromSafeLogicalRecord() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-closed-local-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("history.json")
        let recordID = UUID()
        let panelID = UUID()
        let sessionID = UUID().uuidString.lowercased()
        let secret = "closed-local-argv-env-secret-sentinel"
        let root = "/Users/test/Projects/Closed Local"
        let terminal = SessionTerminalPanelSnapshot(
            workingDirectory: root,
            agent: SessionRestorableAgentSnapshot(
                kind: .claude,
                sessionId: sessionID,
                workingDirectory: root,
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: "/bin/zsh",
                    executablePath: "/sentinel/captured/claude",
                    arguments: ["claude", "--api-key", secret],
                    workingDirectory: root,
                    environment: ["ANTHROPIC_API_KEY": secret],
                    capturedAt: 2_000_010,
                    source: "agent-hook"
                )
            ),
            wasAgentRunning: true,
            uniConnectClaudeSession: sessionID
        )
        let appSnapshot = makeSnapshot(
            workspaceName: "Closed local",
            workspaceDirectory: root,
            panelID: panelID,
            panelName: "Reusable conversation",
            terminal: terminal,
            profile: UniConnectWorkspaceProfile(kind: .local, localRoot: root)
        )
        let panel = try XCTUnwrap(appSnapshot.windows.first?.tabManager.workspaces.first?.panels.first)
        let store = ClosedItemHistoryStore(
            capacity: nil,
            fileURL: fileURL,
            loadPersisted: false,
            persistsRecordsSynchronously: true
        )
        store.push(ClosedItemHistoryRecord(
            id: recordID,
            closedAt: Date(timeIntervalSince1970: 2_000_020),
            entry: .panel(ClosedPanelHistoryEntry(
                workspaceId: UUID(),
                paneId: UUID(),
                tabIndex: 0,
                snapshot: panel,
                uniConnectProfile: UniConnectWorkspaceProfile(kind: .local, localRoot: root)
            ))
        ))

        let readableText = String(decoding: try Data(contentsOf: fileURL), as: UTF8.self)
        XCTAssertFalse(readableText.contains(secret))
        XCTAssertFalse(readableText.contains("ANTHROPIC_API_KEY"))
        XCTAssertFalse(readableText.contains("/sentinel/captured/claude"))
        XCTAssertFalse(readableText.contains("--api-key"))

        let reloaded = ClosedItemHistoryStore(
            capacity: nil,
            fileURL: fileURL,
            loadPersisted: true,
            loadsPersistedRecordsSynchronously: true,
            persistsRecordsSynchronously: true
        )
        let record = try XCTUnwrap(reloaded.record(id: recordID))
        guard case .panel(let restored) = record.entry else {
            return XCTFail("Expected a closed panel history entry")
        }
        XCTAssertEqual(restored.uniConnectProfile?.kind, .local)
        XCTAssertEqual(restored.uniConnectProfile?.localRoot, root)
        XCTAssertEqual(restored.snapshot.terminal?.uniConnectLocalWindow?.boxRoot, root)
        XCTAssertEqual(restored.snapshot.terminal?.uniConnectLocalWindow?.latestConversation?.sessionID, sessionID)
        XCTAssertEqual(restored.snapshot.terminal?.agent?.launchCommand?.executablePath, "claude")
        XCTAssertEqual(
            restored.snapshot.terminal?.agent?.launchCommand?.arguments,
            ["claude", "--dangerously-skip-permissions"]
        )
        XCTAssertNil(restored.snapshot.terminal?.agent?.launchCommand?.environment)
    }

    @MainActor
    func testClosedSSHWorkspaceHistoryKeepsOpaqueRecoveryLinksAndStripsConnectionMaterial() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-closed-ssh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("history.json")
        let recordID = UUID()
        let credentialID = UUID()
        let panelID = UUID()
        let secret = "closed-ssh-connection-secret-sentinel"
        let tmuxName = "uc-recoverable-session"
        let terminal = SessionTerminalPanelSnapshot(
            workingDirectory: "/srv/project",
            scrollback: "sshpass -p '\(secret)' ssh root@secret.example",
            agent: SessionRestorableAgentSnapshot(
                kind: .claude,
                sessionId: UUID().uuidString.lowercased(),
                workingDirectory: "/srv/project",
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: nil,
                    executablePath: "sshpass",
                    arguments: ["sshpass", "-p", secret, "ssh", "root@secret.example"],
                    workingDirectory: "/srv/project",
                    environment: ["SSH_PASSWORD": secret],
                    capturedAt: 2_000_025,
                    source: "agent-hook"
                )
            ),
            tmuxStartCommand: "sshpass -p '\(secret)' ssh root@secret.example",
            resumeBinding: SurfaceResumeBindingSnapshot(command: "sshpass -p '\(secret)' ssh root@secret.example"),
            wasAgentRunning: true,
            uniConnectTmuxSession: tmuxName
        )
        var appSnapshot = makeSnapshot(
            workspaceName: "SSH box",
            workspaceDirectory: "/srv/project",
            panelID: panelID,
            panelName: "Remote task",
            terminal: terminal,
            profile: UniConnectWorkspaceProfile(
                kind: .ssh,
                credentialId: credentialID,
                hostLabel: "root@secret.example",
                tmuxReady: true
            )
        )
        appSnapshot.windows[0].tabManager.workspaces[0].remote = SessionRemoteWorkspaceSnapshot(
            transport: .ssh,
            destination: "root@\(secret).example",
            port: 2222,
            identityFile: "/Users/test/.ssh/\(secret).pem",
            sshOptions: ["PasswordAuthentication=\(secret)", "ProxyCommand=echo \(secret)"],
            preserveAfterTerminalExit: true,
            skipDaemonBootstrap: nil
        )
        let workspace = appSnapshot.windows[0].tabManager.workspaces[0]
        let store = ClosedItemHistoryStore(
            capacity: nil,
            fileURL: fileURL,
            loadPersisted: false,
            persistsRecordsSynchronously: true
        )
        store.push(ClosedItemHistoryRecord(
            id: recordID,
            closedAt: Date(timeIntervalSince1970: 2_000_030),
            entry: .workspace(ClosedWorkspaceHistoryEntry(
                workspaceId: try XCTUnwrap(workspace.workspaceId),
                windowId: UUID(),
                workspaceIndex: 0,
                snapshot: workspace
            ))
        ))

        let readableText = String(decoding: try Data(contentsOf: fileURL), as: UTF8.self)
        XCTAssertFalse(readableText.contains(secret))
        XCTAssertFalse(readableText.localizedCaseInsensitiveContains("sshpass"))
        XCTAssertFalse(readableText.contains("PasswordAuthentication"))
        XCTAssertFalse(readableText.contains("ProxyCommand"))
        XCTAssertTrue(readableText.contains(credentialID.uuidString))
        XCTAssertTrue(readableText.contains(tmuxName))

        let reloaded = ClosedItemHistoryStore(
            capacity: nil,
            fileURL: fileURL,
            loadPersisted: true,
            loadsPersistedRecordsSynchronously: true,
            persistsRecordsSynchronously: true
        )
        let record = try XCTUnwrap(reloaded.record(id: recordID))
        guard case .workspace(let restored) = record.entry else {
            return XCTFail("Expected a closed workspace history entry")
        }
        XCTAssertNil(restored.snapshot.remote)
        XCTAssertEqual(restored.snapshot.uniConnect?.credentialId, credentialID)
        XCTAssertEqual(restored.snapshot.panels.first?.terminal?.uniConnectTmuxSession, tmuxName)
        XCTAssertEqual(
            restored.snapshot.currentDirectory,
            FileManager.default.homeDirectoryForCurrentUser.path
        )
        XCTAssertNil(restored.snapshot.panels.first?.directory)
        XCTAssertNil(restored.snapshot.panels.first?.terminal?.workingDirectory)
        XCTAssertNil(restored.snapshot.panels.first?.terminal?.agent)
        XCTAssertNil(restored.snapshot.panels.first?.terminal?.scrollback)
        XCTAssertNil(restored.snapshot.panels.first?.terminal?.tmuxStartCommand)
        XCTAssertNil(restored.snapshot.panels.first?.terminal?.resumeBinding)
    }

    func testCompactRailModeRoundTripsPerWindow() throws {
        var snapshot = makeSnapshot()
        snapshot.windows[0].sidebar.uniConnectCompact = true
        let data = try SessionPersistenceStore.encodedSnapshotDataForPersistence(snapshot)
        let restored = try JSONDecoder().decode(AppSessionSnapshot.self, from: data)
        XCTAssertEqual(restored.windows.first?.sidebar.uniConnectCompact, true)
    }

    func testRecoveryRepositoryCreatesAtMostOneScheduledBackupPerSixHours() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-recovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = UniConnectRecoveryBackupRepository(rootDirectory: directory)
        let start = Date(timeIntervalSince1970: 2_000_000)

        let first = try await repository.archiveIfDue(
            snapshot: makeSnapshot(),
            encryptedVault: nil,
            now: start
        )
        let tooSoon = try await repository.archiveIfDue(
            snapshot: makeSnapshot(),
            encryptedVault: nil,
            now: start.addingTimeInterval(21_599)
        )
        let second = try await repository.archiveIfDue(
            snapshot: makeSnapshot(),
            encryptedVault: nil,
            now: start.addingTimeInterval(21_600)
        )

        XCTAssertNotNil(first)
        XCTAssertNil(tooSoon)
        XCTAssertNotNil(second)
        let backups = try await repository.availableBackups(now: start.addingTimeInterval(21_600))
        XCTAssertEqual(backups.count, 2)
    }

    func testRecoveryRepositorySecuresEntireManagedDirectoryChain() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-recovery-permissions-\(UUID().uuidString)", isDirectory: true)
        let managedRoot = fixture.appendingPathComponent(".uniconnect", isDirectory: true)
        let backups = managedRoot.appendingPathComponent("backups", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixture) }

        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: managedRoot.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: backups.path
        )

        let repository = UniConnectRecoveryBackupRepository(rootDirectory: backups)
        let entry = try await repository.archive(
            snapshot: makeSnapshot(),
            encryptedVault: nil,
            reason: .scheduled,
            now: Date(timeIntervalSince1970: 2_000_000)
        )

        for directory in [managedRoot, backups] {
            let mode = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
            ).intValue
            XCTAssertEqual(mode & 0o777, 0o700, "Expected private directory: \(directory.path)")
        }
        let snapshotMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: entry.snapshotURL.path)[.posixPermissions] as? NSNumber
        ).intValue
        XCTAssertEqual(snapshotMode & 0o777, 0o600)
    }

    func testFutureDatedBackupDoesNotSuppressCurrentCadence() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-clock-rollback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = UniConnectRecoveryBackupRepository(rootDirectory: directory)
        let now = Date(timeIntervalSince1970: 2_000_000)

        _ = try await repository.archive(
            snapshot: makeSnapshot(),
            encryptedVault: nil,
            reason: .scheduled,
            now: now.addingTimeInterval(24 * 60 * 60)
        )
        let current = try await repository.archiveIfDue(
            snapshot: makeSnapshot(),
            encryptedVault: nil,
            now: now
        )
        let duplicate = try await repository.archiveIfDue(
            snapshot: makeSnapshot(),
            encryptedVault: nil,
            now: now.addingTimeInterval(1)
        )

        XCTAssertNotNil(current)
        XCTAssertNil(duplicate)
        let backups = try await repository.availableBackups(now: now.addingTimeInterval(1))
        let currentURL = try XCTUnwrap(current?.snapshotURL).resolvingSymlinksInPath()
        XCTAssertEqual(
            backups.map { $0.snapshotURL.resolvingSymlinksInPath() },
            [currentURL]
        )
    }

    func testRecoveryPickerCannotEscapeArchiveThroughSymlinkDirectory() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-recovery-path-\(UUID().uuidString)", isDirectory: true)
        let directory = fixture.appendingPathComponent("backups", isDirectory: true)
        let outside = fixture.appendingPathComponent("outside", isDirectory: true)
        let outsideChild = outside.appendingPathComponent("child", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideChild, withIntermediateDirectories: true)
        let filename = "session-2000000000-scheduled-\(UUID().uuidString.lowercased()).json"
        let outsideSnapshot = outside.appendingPathComponent(filename)
        XCTAssertTrue(SessionPersistenceStore.save(makeSnapshot(), fileURL: outsideSnapshot))
        let link = directory.appendingPathComponent("outside-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let escapedCandidate = link.appendingPathComponent(filename)
        let repository = UniConnectRecoveryBackupRepository(rootDirectory: directory)
        let loadedSnapshot = await repository.loadSnapshot(from: escapedCandidate)
        let loadedVaultURL = await repository.encryptedVaultURL(for: escapedCandidate)
        let traversalLink = directory.appendingPathComponent("outside-child", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: traversalLink, withDestinationURL: outsideChild)
        let symlinkTraversalCandidate = URL(
            fileURLWithPath: traversalLink.path + "/../" + filename
        )
        let traversalSnapshot = await repository.loadSnapshot(from: symlinkTraversalCandidate)
        let traversalVaultURL = await repository.encryptedVaultURL(for: symlinkTraversalCandidate)

        XCTAssertNil(loadedSnapshot)
        XCTAssertNil(loadedVaultURL)
        XCTAssertNil(traversalSnapshot)
        XCTAssertNil(traversalVaultURL)
    }

    func testRecoveryRepositoryPrunesByAgeAndCount() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-retention-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let policy = UniConnectRecoveryBackupPolicy(interval: 1, retention: 100, maximumCount: 2)
        let repository = UniConnectRecoveryBackupRepository(rootDirectory: directory, policy: policy)
        let start = Date(timeIntervalSince1970: 2_000_000)

        for offset in [0.0, 10.0, 20.0] {
            _ = try await repository.archiveIfDue(
                snapshot: makeSnapshot(),
                encryptedVault: nil,
                now: start.addingTimeInterval(offset)
            )
        }
        var backups = try await repository.availableBackups(now: start.addingTimeInterval(20))
        XCTAssertEqual(backups.count, 2)

        backups = try await repository.availableBackups(now: start.addingTimeInterval(121))
        XCTAssertTrue(backups.isEmpty)
    }

    func testBeforeRestoreBackupsCannotEvictScheduledRecoveryHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-separated-retention-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let policy = UniConnectRecoveryBackupPolicy(
            interval: 1,
            retention: 1_000,
            maximumCount: 4,
            maximumBeforeRestoreCount: 2
        )
        let repository = UniConnectRecoveryBackupRepository(
            rootDirectory: directory,
            policy: policy
        )
        let start = Date(timeIntervalSince1970: 2_000_000)

        for offset in 0..<8 {
            let now = start.addingTimeInterval(TimeInterval(offset))
            _ = try await repository.archive(
                snapshot: makeSnapshot(),
                encryptedVault: nil,
                reason: .scheduled,
                now: now
            )
            _ = try await repository.archive(
                snapshot: makeSnapshot(),
                encryptedVault: nil,
                reason: .beforeRestore,
                now: now.addingTimeInterval(0.25)
            )
        }

        let backups = try await repository.availableBackups(
            now: start.addingTimeInterval(8)
        )
        XCTAssertEqual(backups.filter { $0.reason == .scheduled }.count, 4)
        XCTAssertEqual(backups.filter { $0.reason == .beforeRestore }.count, 2)
        XCTAssertEqual(backups.count, 6)
    }

    func testSSHRecoveryArchiveNeverCommitsReadableSnapshotWithoutVaultCompanion() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-recovery-missing-vault-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = UniConnectRecoveryBackupRepository(rootDirectory: directory)
        let snapshot = makeSnapshot(profile: UniConnectWorkspaceProfile(
            kind: .ssh,
            credentialId: UUID(),
            hostLabel: "root@example.test",
            tmuxReady: true
        ))

        do {
            _ = try await repository.archive(
                snapshot: snapshot,
                encryptedVault: nil,
                reason: .scheduled
            )
            XCTFail("Expected the SSH archive to require its encrypted companion")
        } catch {
            XCTAssertTrue(error is UniConnectError)
        }
        let backups = try await repository.availableBackups()
        XCTAssertTrue(backups.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testPostRenameSnapshotSyncFailureKeepsItsEncryptedVaultCompanion() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-recovery-post-rename-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = UniConnectRecoveryBackupRepository(
            rootDirectory: directory,
            fileWriter: { data, destination, fileManager in
                try UniConnectAtomicFileWriter.write(
                    data,
                    to: destination,
                    fileManager: fileManager
                )
                if destination.pathExtension == "json" {
                    throw UniConnectAtomicFileWriter.WriteError.directorySyncFailed(5)
                }
            }
        )
        let snapshot = makeSnapshot(profile: UniConnectWorkspaceProfile(
            kind: .ssh,
            credentialId: UUID(),
            hostLabel: "root@example.test",
            tmuxReady: true
        ))

        do {
            _ = try await repository.archive(
                snapshot: snapshot,
                encryptedVault: Data("encrypted-vault".utf8),
                reason: .scheduled
            )
            XCTFail("Expected the injected post-rename directory sync failure")
        } catch UniConnectAtomicFileWriter.WriteError.directorySyncFailed(_) {
            // The destination is visible even though its final durability sync was uncertain.
        }

        let backups = try await repository.availableBackups()
        let recovered = try XCTUnwrap(backups.first)
        XCTAssertEqual(backups.count, 1)
        XCTAssertNotNil(recovered.encryptedVaultURL)
        XCTAssertEqual(
            try await repository.loadEncryptedVault(for: recovered.snapshotURL),
            Data("encrypted-vault".utf8)
        )
    }

    func testRecoveryRepositoryWritesTheAlreadyCapturedVaultRevision() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-recovery-captured-vault-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = UniConnectRecoveryBackupRepository(rootDirectory: directory)
        let captured = Data("captured-revision".utf8)

        let entry = try await repository.archive(
            snapshot: makeSnapshot(),
            encryptedVault: captured,
            reason: .scheduled
        )

        let companion = try XCTUnwrap(entry.encryptedVaultURL)
        XCTAssertEqual(try Data(contentsOf: companion), captured)
    }

    @MainActor
    func testFailedRecoveryRestoresVaultCiphertextByteForByte() async throws {
        let fixture = try makeVaultCollisionFixture()
        var archivedVault: Data?
        let transaction = UniConnectRecoveryRestoreTransaction(
            snapshotProvider: { self.makeSnapshot() },
            snapshotRestorer: { _ in false },
            currentSnapshotArchiver: { _, encryptedVault in
                archivedVault = encryptedVault
            },
            vaultSnapshotProvider: { credentialIDs in
                try fixture.current.encryptedSnapshot(requiring: credentialIDs)
            },
            vaultMerger: { encrypted in
                try fixture.current.mergeEncryptedBackup(encrypted)
            },
            vaultRestorer: { encrypted in
                try fixture.current.restoreExactEncryptedSnapshot(encrypted)
            }
        )

        do {
            try await transaction.execute(
                recoveredSnapshot: fixture.recoveredSnapshot,
                recoveredVault: fixture.backupBytes
            )
            XCTFail("Expected the simulated snapshot restorer failure")
        } catch {
            XCTAssertEqual(try fixture.current.encryptedSnapshot(), fixture.currentBytes)
            XCTAssertEqual(archivedVault, fixture.currentBytes)
            XCTAssertEqual(fixture.current.connectCommand(for: fixture.credentialID), fixture.currentCommand)
            XCTAssertEqual(fixture.current.allIds(), [fixture.credentialID])
        }
    }

    @MainActor
    func testRecoveryCredentialCollisionCreatesImmutableRevisionAndRemapsSnapshot() async throws {
        let fixture = try makeVaultCollisionFixture()
        var restoredCredentialID: UUID?
        let transaction = UniConnectRecoveryRestoreTransaction(
            snapshotProvider: { nil },
            snapshotRestorer: { snapshot in
                restoredCredentialID = snapshot.windows.first?
                    .tabManager.workspaces.first?.uniConnect?.credentialId
                return true
            },
            currentSnapshotArchiver: { _, _ in },
            vaultSnapshotProvider: { credentialIDs in
                try fixture.current.encryptedSnapshot(requiring: credentialIDs)
            },
            vaultMerger: { encrypted in
                try fixture.current.mergeEncryptedBackup(encrypted)
            },
            vaultRestorer: { encrypted in
                try fixture.current.restoreExactEncryptedSnapshot(encrypted)
            }
        )

        try await transaction.execute(
            recoveredSnapshot: fixture.recoveredSnapshot,
            recoveredVault: fixture.backupBytes
        )

        let revisionID = try XCTUnwrap(restoredCredentialID)
        XCTAssertNotEqual(revisionID, fixture.credentialID)
        XCTAssertEqual(fixture.current.connectCommand(for: fixture.credentialID), fixture.currentCommand)
        XCTAssertEqual(fixture.current.connectCommand(for: revisionID), fixture.recoveredCommand)
        XCTAssertEqual(fixture.current.allIds().count, 2)
    }

    func testConnectionEditCreatesNewCredentialRevisionWithoutRetargetingOldHistory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-vault-edit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(data: Data(repeating: 0x31, count: 32))
        let vault = UniConnectVault(
            storageURL: directory.appendingPathComponent("vault.uc"),
            keyProvider: { key }
        )
        let oldID = UUID(uuidString: "61000000-0000-0000-0000-000000000001")!
        let newID = UUID(uuidString: "61000000-0000-0000-0000-000000000002")!
        let oldCommand = "ssh deploy@old.example"
        let newCommand = "ssh deploy@new.example"
        try vault.storeOrThrow(connectCommand: oldCommand, id: oldID)

        let createdID = try vault.createImmutableRevision(
            connectCommand: newCommand,
            id: newID
        )

        XCTAssertEqual(createdID, newID)
        XCTAssertEqual(vault.connectCommand(for: oldID), oldCommand)
        XCTAssertEqual(vault.connectCommand(for: newID), newCommand)
        XCTAssertThrowsError(
            try vault.createImmutableRevision(
                connectCommand: "ssh deploy@third.example",
                id: oldID
            )
        )
        XCTAssertEqual(vault.connectCommand(for: oldID), oldCommand)
    }

    func testReleaseMasterKeyMigrationNeverPrefersAConflictingKeychainKey() {
        let fallback = Data(repeating: 1, count: 32)
        let keychain = Data(repeating: 2, count: 32)
        XCTAssertEqual(
            UniConnectMasterKeyMigrationPolicy.action(fallback: fallback, keychain: keychain),
            .migrateFallbackToKeychain
        )
        XCTAssertEqual(
            UniConnectMasterKeyMigrationPolicy.action(fallback: nil, keychain: keychain),
            .useKeychain
        )
        XCTAssertEqual(
            UniConnectMasterKeyMigrationPolicy.action(fallback: Data(repeating: 1, count: 31), keychain: keychain),
            .failInvalidFallback
        )
        XCTAssertEqual(
            UniConnectMasterKeyMigrationPolicy.action(fallback: nil, keychain: Data(repeating: 2, count: 31)),
            .failInvalidKeychain
        )
        XCTAssertTrue(
            UniConnectMasterKeyMigrationPolicy.permitsNewKey(hasExistingEncryptedState: false)
        )
        XCTAssertFalse(
            UniConnectMasterKeyMigrationPolicy.permitsNewKey(hasExistingEncryptedState: true)
        )
    }

    @MainActor
    func testPersistenceObserverRequestsSaveForEveryRecoveryRelevantMutation() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try XCTUnwrap(manager.tabs.first)
        var reasons: [String] = []
        let observer = UniConnectSessionPersistenceObserver(tabManager: manager) { reason in
            reasons.append(reason)
        }

        workspace.setCustomTitle("Renamed")
        workspace.setCustomColor("#ABCDEF")
        workspace.uniConnectProfile = UniConnectWorkspaceProfile(kind: .local, importIdentity: UUID())
        if let panelID = workspace.panels.keys.first {
            workspace.panelDirectories[panelID] = "/tmp/exact"
            workspace.panelCustomTitles[panelID] = "Claude"
            workspace.uniConnectTmuxSessionsByPanelId[panelID] = "uc-claude"
            workspace.uniConnectClaudeSessionsByPanelId[panelID] = UUID().uuidString
            NotificationCenter.default.post(
                name: .uniConnectClaudeSessionSignal,
                object: UniConnectClaudeSessionSignal(
                    workspaceID: workspace.id,
                    panelID: panelID,
                    kind: .lifecycleChanged,
                    lifecycle: "running",
                    shellActivity: nil
                )
            )
        }
        manager.selectedTabId = nil

        XCTAssertTrue(reasons.contains("workspace-custom-name"))
        XCTAssertTrue(reasons.contains("workspace-color"))
        XCTAssertTrue(reasons.contains("connection-profile-reference"))
        XCTAssertTrue(reasons.contains("window-directory"))
        XCTAssertTrue(reasons.contains("window-custom-name"))
        XCTAssertTrue(reasons.contains("window-tmux-binding"))
        XCTAssertTrue(reasons.contains("window-claude-session"))
        XCTAssertTrue(reasons.contains("window-claude-runtime-state"))
        XCTAssertTrue(reasons.contains("selected-workspace"))
        _ = observer
    }

    private func makeSnapshot(
        workspaceName: String = "Workspace",
        workspaceDirectory: String = "/tmp/project",
        panelID: UUID = UUID(),
        panelName: String = "Window",
        terminal: SessionTerminalPanelSnapshot = SessionTerminalPanelSnapshot(workingDirectory: "/tmp/project"),
        profile: UniConnectWorkspaceProfile = .local
    ) -> AppSessionSnapshot {
        let panel = SessionPanelSnapshot(
            id: panelID,
            type: .terminal,
            title: panelName,
            customTitle: panelName,
            directory: terminal.workingDirectory,
            isPinned: false,
            isManuallyUnread: false,
            gitBranch: nil,
            listeningPorts: [],
            ttyName: nil,
            terminal: terminal,
            browser: nil,
            markdown: nil,
            filePreview: nil,
            rightSidebarTool: nil,
            project: nil
        )
        let workspace = SessionWorkspaceSnapshot(
            workspaceId: UUID(),
            processTitle: workspaceName,
            customTitle: workspaceName,
            customDescription: nil,
            customColor: "#123456",
            isPinned: false,
            currentDirectory: workspaceDirectory,
            focusedPanelId: panelID,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [panelID], selectedPanelId: panelID)),
            panels: [panel],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil,
            remote: nil,
            uniConnect: profile
        )
        return AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 2_000_000,
            windows: [
                SessionWindowSnapshot(
                    windowId: UUID(),
                    frame: nil,
                    display: nil,
                    tabManager: SessionTabManagerSnapshot(
                        selectedWorkspaceIndex: 0,
                        workspaces: [workspace]
                    ),
                    sidebar: SessionSidebarSnapshot(
                        isVisible: true,
                        selection: .tabs,
                        width: 248,
                        uniConnectCompact: false
                    )
                )
            ]
        )
    }

    private struct VaultCollisionFixture {
        let current: UniConnectVault
        let credentialID: UUID
        let currentCommand: String
        let recoveredCommand: String
        let currentBytes: Data
        let backupBytes: Data
        let recoveredSnapshot: AppSessionSnapshot
    }

    private func makeVaultCollisionFixture() throws -> VaultCollisionFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-vault-collision-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(data: Data(repeating: 0xA7, count: 32))
        let current = UniConnectVault(
            storageURL: directory.appendingPathComponent("current.uc"),
            keyProvider: { key }
        )
        let backup = UniConnectVault(
            storageURL: directory.appendingPathComponent("backup.uc"),
            keyProvider: { key }
        )
        let credentialID = UUID()
        let currentCommand = "ssh current@example.test"
        let recoveredCommand = "ssh recovered@example.test"
        try current.storeOrThrow(connectCommand: currentCommand, id: credentialID)
        try backup.storeOrThrow(connectCommand: recoveredCommand, id: credentialID)
        let currentBytes = try XCTUnwrap(current.encryptedSnapshot())
        let backupBytes = try XCTUnwrap(backup.encryptedSnapshot())
        let recoveredSnapshot = makeSnapshot(profile: UniConnectWorkspaceProfile(
            kind: .ssh,
            credentialId: credentialID,
            hostLabel: "recovered@example.test",
            tmuxReady: true
        ))
        return VaultCollisionFixture(
            current: current,
            credentialID: credentialID,
            currentCommand: currentCommand,
            recoveredCommand: recoveredCommand,
            currentBytes: currentBytes,
            backupBytes: backupBytes,
            recoveredSnapshot: recoveredSnapshot
        )
    }
}
