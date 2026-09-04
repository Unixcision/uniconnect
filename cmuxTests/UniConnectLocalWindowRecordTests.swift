import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("UniConnect persistent local windows")
struct UniConnectLocalWindowRecordTests {
    private let emptyRegistry = CmuxVaultAgentRegistry(registrations: [])

    @Test("Switching agents appends history and makes the newest conversation resumable")
    func switchingAgentsPreservesEveryConversation() throws {
        var record = UniConnectLocalWindowRecord(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            visibleName: "Implementation",
            boxRoot: "/Users/test/Projects/Box Root",
            createdAt: 100,
            updatedAt: 100
        )
        let claude = agent(.claude, sessionID: "20000000-0000-0000-0000-000000000001")
        let codex = agent(.codex, sessionID: "codex-thread-1")
        let agy = agent(.antigravity, sessionID: "agy-conversation-1")

        let recordedClaude = record.record(claude, at: 101)
        #expect(recordedClaude)
        let leftClaude = record.transitionToShell(at: 102)
        #expect(leftClaude)
        let recordedCodex = record.record(codex, at: 103)
        #expect(recordedCodex)
        let leftCodex = record.transitionToShell(at: 104)
        #expect(leftCodex)
        let recordedAgy = record.record(agy, at: 105)
        #expect(recordedAgy)

        #expect(record.conversations.map(\.kind) == [.claude, .codex, .antigravity])
        #expect(record.latestConversation?.sessionID == "agy-conversation-1")
        #expect(record.activeConversation?.sessionID == "agy-conversation-1")
        #expect(record.runtimeState == .agent)
        let resume = try #require(record.latestRestorableSnapshot(registry: emptyRegistry)?.resumeCommand)
        #expect(resume.contains("agy"))
        #expect(resume.contains("--conversation"))
        #expect(resume.contains("--dangerously-skip-permissions"))
        #expect(resume.contains("/Users/test/Projects/Box Root"))
    }

    @Test("Returning to shell or stopping never drops the saved conversation")
    func shellAndStoppedStatesRetainLatestConversation() throws {
        var record = UniConnectLocalWindowRecord(
            visibleName: "Review",
            boxRoot: "/Users/test/repository",
            createdAt: 200,
            updatedAt: 200
        )
        let recordedCodex = record.record(agent(.codex, sessionID: "codex-thread-2"), at: 201)
        #expect(recordedCodex)
        let latestID = try #require(record.latestConversationID)

        let transitionedToShell = record.transitionToShell(at: 202)
        #expect(transitionedToShell)
        #expect(record.runtimeState == .shell)
        #expect(record.activeConversationID == nil)
        #expect(record.latestConversationID == latestID)
        #expect(record.conversations.count == 1)

        let markedStopped = record.markStopped(at: 203)
        #expect(markedStopped)
        #expect(record.runtimeState == .stopped)
        #expect(record.latestConversationID == latestID)
        #expect(record.conversations.count == 1)
        let resume = try #require(record.latestRestorableSnapshot(registry: emptyRegistry)?.resumeCommand)
        #expect(resume.contains("codex"))
        #expect(resume.contains("resume"))
        #expect(resume.contains("--yolo"))
    }

    @Test("UUID-shaped session identifiers deduplicate independent of letter case")
    func uuidSessionIdentityIsCanonical() throws {
        let uppercase = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
        let lowercase = uppercase.lowercased()
        var record = UniConnectLocalWindowRecord(
            boxRoot: "/Users/test/repository",
            createdAt: 250,
            updatedAt: 250
        )

        let recordedUppercase = record.record(agent(.claude, sessionID: uppercase), at: 251)
        #expect(recordedUppercase)
        let originalID = try #require(record.latestConversationID)
        let transitionedToShell = record.transitionToShell(at: 252)
        #expect(transitionedToShell)
        let recordedLowercase = record.record(agent(.claude, sessionID: lowercase), at: 253)
        #expect(recordedLowercase)

        #expect(record.conversations.count == 1)
        #expect(record.latestConversationID == originalID)
        #expect(record.activeConversationID == originalID)
    }

    @Test("Only explicit forget removes a conversation and falls back to prior history")
    func explicitForgetIsTheOnlyDestructiveTransition() throws {
        var record = UniConnectLocalWindowRecord(
            boxRoot: "/Users/test/repository",
            createdAt: 300,
            updatedAt: 300
        )
        _ = record.record(agent(.claude, sessionID: "30000000-0000-0000-0000-000000000001"), at: 301)
        _ = record.transitionToShell(at: 302)
        _ = record.record(agent(.grok, sessionID: "grok-session-1"), at: 303)
        let grokID = try #require(record.latestConversationID)
        let grokResume = try #require(
            record.latestRestorableSnapshot(registry: emptyRegistry)?.resumeCommand
        )
        #expect(grokResume.contains("'grok' '-r' 'grok-session-1'"))

        let forgotGrok = record.forgetConversation(id: grokID, at: 304)
        #expect(forgotGrok)
        #expect(record.conversations.count == 1)
        #expect(record.latestConversation?.kind == .claude)
        #expect(record.runtimeState == .shell)
        let forgotGrokAgain = record.forgetConversation(id: grokID, at: 305)
        #expect(!forgotGrokAgain)
    }

    @Test("Legacy Claude binding migrates and survives a Codable round trip in shell state")
    func legacyClaudeMigrationRoundTripsWithoutAutoForgetting() throws {
        let sessionID = "40000000-0000-0000-0000-000000000001"
        var record = UniConnectLocalWindowRecord.migratingLegacy(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000002")!,
            visibleName: "Claude review",
            boxRoot: "/Users/test/Legacy Box",
            agent: nil,
            claudeSession: sessionID,
            wasAgentRunning: false,
            timestamp: 400
        )
        #expect(record.runtimeState == .shell)
        #expect(record.legacyClaudeSession == sessionID)
        #expect(record.latestConversation?.kind == .claude)

        let data = try JSONEncoder().encode(record)
        record = try JSONDecoder().decode(UniConnectLocalWindowRecord.self, from: data)
        #expect(record.runtimeState == .shell)
        #expect(record.latestConversation?.sessionID == sessionID)
        #expect(record.activeConversationID == nil)
    }

    @Test("Version-one local-window records migrate their cwd to the trusted root")
    func versionOneLocalWindowMigratesWorkingDirectory() throws {
        let data = Data(
            #"{"version":1,"id":"41000000-0000-0000-0000-000000000001","visibleName":"API","boxRoot":"/repo","runtimeState":"shell","conversations":[],"createdAt":1,"updatedAt":2}"#.utf8
        )

        let record = try JSONDecoder().decode(UniConnectLocalWindowRecord.self, from: data)

        #expect(record.version == 2)
        #expect(record.boxRoot == "/repo")
        #expect(record.workingDirectory == "/repo")
        let encoded = try JSONEncoder().encode(record)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["version"] as? Int == 2)
        #expect(object["workingDirectory"] as? String == "/repo")
    }

    @Test("Two local windows retain distinct cwd values through document coding")
    func twoWindowWorkingDirectoriesRoundTrip() throws {
        func window(id: String, name: String, cwd: String) -> UniConnectDocument.Window {
            UniConnectDocument.Window(
                name: name,
                tmux: nil,
                claudeSession: nil,
                cwd: cwd,
                isPinned: nil,
                localWindow: UniConnectLocalWindowRecord(
                    id: UUID(uuidString: id)!,
                    visibleName: name,
                    boxRoot: "/repo",
                    workingDirectory: cwd,
                    createdAt: 1,
                    updatedAt: 1
                )
            )
        }
        let document = UniConnectDocument(
            workspaces: [
                .init(
                    name: "Repository",
                    kind: .local,
                    color: nil,
                    group: nil,
                    isPinned: nil,
                    cwd: "/repo",
                    connect: nil,
                    windows: [
                        window(
                            id: "42000000-0000-0000-0000-000000000001",
                            name: "API",
                            cwd: "/repo/api"
                        ),
                        window(
                            id: "42000000-0000-0000-0000-000000000002",
                            name: "Web",
                            cwd: "/repo/web"
                        ),
                    ]
                ),
            ],
            savedAt: Date(timeIntervalSince1970: 1)
        )

        let decoded = try JSONDecoder().decode(
            UniConnectDocument.self,
            from: JSONEncoder().encode(document)
        )
        let windows = try #require(decoded.workspaces.first?.windows)

        #expect(decoded.workspaces.first?.cwd == "/repo")
        #expect(windows.map(\.cwd) == ["/repo/api", "/repo/web"])
        #expect(windows.compactMap { $0.localWindow?.workingDirectory } == ["/repo/api", "/repo/web"])
        #expect(windows.allSatisfy { $0.localWindow?.boxRoot == "/repo" })
    }

    @Test("Version-one UniConnect documents decode without generic local-window state")
    func versionOneDocumentRemainsDecodable() throws {
        let data = Data(
            #"{"version":1,"app":"UniConnect","savedAt":"2026-01-01T00:00:00Z","workspaces":[{"name":"Legacy","kind":"local","cwd":"/Users/test/legacy","windows":[{"name":"Claude","claudeSession":"40000000-0000-0000-0000-000000000001"}]}]}"#.utf8
        )

        let document = try JSONDecoder().decode(UniConnectDocument.self, from: data)

        #expect(document.version == 1)
        #expect(document.workspaces.first?.windows.first?.localWindow == nil)
        #expect(
            document.workspaces.first?.windows.first?.claudeSession
                == "40000000-0000-0000-0000-000000000001"
        )
    }

    @Test("Persistent history does not copy captured argv or environment secrets")
    func historyIsSecretFree() throws {
        let secret = "do-not-persist-this-token"
        let captured = SessionRestorableAgentSnapshot(
            kind: .cursor,
            sessionId: "cursor-session-1",
            workingDirectory: "/Users/test/repository",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: nil,
                executablePath: "/usr/local/bin/cursor-agent",
                arguments: ["cursor-agent", "--api-key", secret],
                workingDirectory: "/Users/test/repository",
                environment: ["API_KEY": secret],
                capturedAt: 500,
                source: "agent-hook"
            )
        )
        var record = UniConnectLocalWindowRecord(
            boxRoot: "/Users/test/repository",
            createdAt: 500,
            updatedAt: 500
        )
        let recordedCapture = record.record(captured, at: 501)
        #expect(recordedCapture)

        let text = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        #expect(!text.contains(secret))
        #expect(!text.contains("API_KEY"))
        #expect(!text.contains("--api-key"))
    }

    @Test("Oversized untrusted local-window fields fail closed during decode")
    func oversizedFieldsAreRejected() throws {
        var conversationObject: [String: Any] = [
            "id": UUID().uuidString,
            "kind": "codex",
            "sessionID": String(
                repeating: "s",
                count: UniConnectLocalAgentConversation.maximumSessionIDUTF8Bytes + 1
            ),
            "displayName": "Codex",
            "firstSeenAt": 1,
        ]
        let conversationData = try JSONSerialization.data(withJSONObject: conversationObject)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(UniConnectLocalAgentConversation.self, from: conversationData)
        }
        conversationObject["sessionID"] = "safe-session"
        conversationObject["displayName"] = String(
            repeating: "d",
            count: UniConnectLocalAgentConversation.maximumDisplayNameUTF8Bytes + 1
        )
        let oversizedDisplayNameData = try JSONSerialization.data(withJSONObject: conversationObject)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                UniConnectLocalAgentConversation.self,
                from: oversizedDisplayNameData
            )
        }

        var recordObject: [String: Any] = [
            "version": 1,
            "id": UUID().uuidString,
            "visibleName": String(
                repeating: "n",
                count: UniConnectLocalWindowRecord.maximumVisibleNameUTF8Bytes + 1
            ),
            "boxRoot": "/Users/test/repository",
            "runtimeState": "shell",
            "conversations": [],
            "createdAt": 1,
            "updatedAt": 1,
        ]
        let recordData = try JSONSerialization.data(withJSONObject: recordObject)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(UniConnectLocalWindowRecord.self, from: recordData)
        }
        recordObject["visibleName"] = "Safe"
        recordObject["boxRoot"] = "/" + String(
            repeating: "r",
            count: UniConnectLocalWindowRecord.maximumBoxRootUTF8Bytes
        )
        let oversizedRootData = try JSONSerialization.data(withJSONObject: recordObject)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(UniConnectLocalWindowRecord.self, from: oversizedRootData)
        }

        recordObject["boxRoot"] = "relative/project"
        let relativeRootData = try JSONSerialization.data(withJSONObject: recordObject)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(UniConnectLocalWindowRecord.self, from: relativeRootData)
        }
        #expect(UniConnectLocalWindowRecord.validatedBoxRoot("relative/project") == nil)
        #expect(UniConnectLocalWindowRecord.validatedBoxRoot("~/project")?.hasPrefix("/") == true)

        recordObject["version"] = 2
        recordObject["boxRoot"] = "/repo"
        recordObject["workingDirectory"] = "/outside/repo"
        let outsideWorkingDirectoryData = try JSONSerialization.data(withJSONObject: recordObject)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(UniConnectLocalWindowRecord.self, from: outsideWorkingDirectoryData)
        }
        recordObject["workingDirectory"] = "repo/api"
        let relativeWorkingDirectoryData = try JSONSerialization.data(withJSONObject: recordObject)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(UniConnectLocalWindowRecord.self, from: relativeWorkingDirectoryData)
        }
        #expect(
            UniConnectLocalWindowRecord.validatedWorkingDirectory("/repo/api", within: "/repo")
                == "/repo/api"
        )
        #expect(
            UniConnectLocalWindowRecord.validatedWorkingDirectory("/repo-other", within: "/repo")
                == nil
        )
    }

    @Test("A cwd cannot escape its trusted root through a symlink")
    func workingDirectoryRejectsSymlinkEscape() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-cwd-\(UUID().uuidString)", isDirectory: true)
        let root = fixture.appendingPathComponent("repo", isDirectory: true)
        let outside = fixture.appendingPathComponent("outside", isDirectory: true)
        let escape = root.appendingPathComponent("escape", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside)

        #expect(
            UniConnectLocalWindowRecord.validatedWorkingDirectory(
                escape.path,
                within: root.path
            ) == nil
        )
        #expect(
            UniConnectLocalWindowRecord.validatedWorkingDirectory(
                escape.appendingPathComponent("not-created/deep", isDirectory: true).path,
                within: root.path
            ) == nil
        )
    }

    @Test("Terminal snapshot round trip retains the generic local-window history")
    func terminalSnapshotRoundTripsGenericHistory() throws {
        var record = UniConnectLocalWindowRecord(
            visibleName: "Mixed agents",
            boxRoot: "/Users/test/repository",
            workingDirectory: "/Users/test/repository/api",
            createdAt: 600,
            updatedAt: 600
        )
        _ = record.record(agent(.claude, sessionID: "60000000-0000-0000-0000-000000000001"), at: 601)
        _ = record.transitionToShell(at: 602)
        _ = record.record(agent(.antigravity, sessionID: "agy-conversation-2"), at: 603)
        _ = record.transitionToShell(at: 604)
        let terminal = SessionTerminalPanelSnapshot(
            workingDirectory: record.workingDirectory,
            agent: record.latestRestorableSnapshot(registry: emptyRegistry),
            wasAgentRunning: false,
            uniConnectClaudeSession: nil,
            uniConnectLocalWindow: record
        )

        let data = try JSONEncoder().encode(terminal)
        let decoded = try JSONDecoder().decode(SessionTerminalPanelSnapshot.self, from: data)
        #expect(decoded.uniConnectLocalWindow == record)
        #expect(decoded.uniConnectLocalWindow?.conversations.count == 2)
        #expect(decoded.uniConnectLocalWindow?.latestConversation?.kind == .antigravity)
        #expect(decoded.uniConnectLocalWindow?.runtimeState == .shell)
        #expect(decoded.workingDirectory == "/Users/test/repository/api")
        #expect(decoded.agent?.workingDirectory == "/Users/test/repository/api")
    }

    private func agent(
        _ kind: RestorableAgentKind,
        sessionID: String
    ) -> SessionRestorableAgentSnapshot {
        SessionRestorableAgentSnapshot(
            kind: kind,
            sessionId: sessionID,
            workingDirectory: "/tmp/a-different-cwd",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: nil,
                executablePath: kind.rawValue,
                arguments: [kind.rawValue],
                workingDirectory: "/tmp/a-different-cwd",
                environment: nil,
                capturedAt: 1,
                source: "test"
            )
        )
    }
}
