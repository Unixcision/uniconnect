import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("UniConnect import reconciliation")
struct UniConnectImportPlannerTests {
    private let planner = UniConnectImportPlanner()

    @Test("Workspace import identity survives session profile coding")
    func persistsWorkspaceImportIdentity() throws {
        let id = UUID(uuidString: "50000000-0000-0000-0000-000000000005")!
        let profile = UniConnectWorkspaceProfile(kind: .local, importIdentity: id)

        let decoded = try JSONDecoder().decode(
            UniConnectWorkspaceProfile.self,
            from: JSONEncoder().encode(profile)
        )

        #expect(decoded.importIdentity == id)
    }

    @Test("A valid new workspace is planned for creation")
    func plansCreateWithoutExistingMatch() {
        let imported = document([local(name: "APP1")])

        let plan = planner.plan(importing: imported, against: document([]))

        #expect(plan.rows.map(\.outcome) == [.create])
        #expect(plan.canUseCreateOnlyExecutor)
        #expect(plan.createRows.map(\.sourceIndex) == [0])
    }

    @Test("CONNECT keeps two local window cwd values under one trusted root")
    func plansDistinctLocalWindowWorkingDirectories() throws {
        func localWindow(id: String, name: String, cwd: String) -> UniConnectDocument.Window {
            .init(
                name: name,
                tmux: nil,
                claudeSession: nil,
                cwd: cwd,
                isPinned: nil,
                localWindow: .init(
                    id: UUID(uuidString: id)!,
                    visibleName: name,
                    boxRoot: "/repo",
                    workingDirectory: cwd,
                    createdAt: 1,
                    updatedAt: 1
                )
            )
        }
        let workspace = UniConnectDocument.Workspace(
            name: "Repository",
            kind: .local,
            color: nil,
            group: nil,
            isPinned: nil,
            cwd: "/repo",
            connect: nil,
            windows: [
                localWindow(
                    id: "51000000-0000-0000-0000-000000000001",
                    name: "API",
                    cwd: "/repo/api"
                ),
                localWindow(
                    id: "51000000-0000-0000-0000-000000000002",
                    name: "Web",
                    cwd: "/repo/web"
                ),
            ]
        )

        let create = planner.plan(importing: document([workspace]), against: document([]))
        let unchanged = planner.plan(
            importing: document([workspace]),
            against: document([workspace])
        )

        #expect(create.rows.map(\.outcome) == [.create])
        #expect(create.rows.first?.issues.isEmpty == true)
        #expect(create.rows.first?.workspace.cwd == "/repo")
        #expect(
            create.rows.first?.workspace.windows.compactMap(\.cwd)
                == ["/repo/api", "/repo/web"]
        )
        #expect(unchanged.rows.map(\.outcome) == [.unchanged])
    }

    @Test("CONNECT rejects a local window cwd outside its trusted root")
    func rejectsLocalWindowWorkingDirectoryOutsideRoot() {
        var imported = local(name: "Repository")
        imported.cwd = "/repo"
        imported.windows[0].cwd = "/tmp/escaped"

        let plan = planner.plan(importing: document([imported]), against: document([]))

        #expect(plan.rows.map(\.outcome) == [.rejected])
        #expect(plan.rows.first?.issues.contains(.invalidLocalWorkingDirectory) == true)
        #expect(plan.rows.first?.windowRows.first?.issues.contains(.invalidLocalWorkingDirectory) == true)
        #expect(plan.createRows.isEmpty)
    }

    @Test("CONNECT rejects conflicting compatibility and durable cwd values")
    func rejectsConflictingLocalWindowWorkingDirectories() {
        var imported = local(name: "Repository")
        imported.cwd = "/repo"
        imported.windows[0].cwd = "/repo/api"
        imported.windows[0].localWindow = UniConnectLocalWindowRecord(
            visibleName: imported.windows[0].name,
            boxRoot: "/repo",
            workingDirectory: "/repo/web",
            createdAt: 1,
            updatedAt: 1
        )

        let plan = planner.plan(importing: document([imported]), against: document([]))

        #expect(plan.rows.map(\.outcome) == [.rejected])
        #expect(plan.rows.first?.issues.contains(.invalidLocalWorkingDirectory) == true)
        #expect(plan.rows.first?.windowRows.first?.issues.contains(.invalidLocalWorkingDirectory) == true)
        #expect(plan.createRows.isEmpty)
    }

    @Test("Stable workspace UUID wins before a changed name")
    func matchesWorkspaceUUIDBeforeName() {
        let id = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let existing = local(id: id, name: "Old name")
        let imported = local(id: id, name: "New name")

        let plan = planner.plan(importing: document([imported]), against: document([existing]))

        #expect(plan.rows.map(\.outcome) == [.update])
        #expect(plan.rows.first?.existingWorkspaceID == id)
        #expect(plan.requiresTransactionalUpdates)
        #expect(!plan.canUseCreateOnlyExecutor)
    }

    @Test("Stable terminal UUID produces an unchanged idempotent plan")
    func matchesClaudeUUIDDeterministically() {
        let session = "11111111-2222-3333-4444-555555555555"
        let workspace = local(name: "APP2", session: session)
        let imported = document([workspace])
        let existing = document([workspace])

        let first = planner.plan(importing: imported, against: existing)
        let second = planner.plan(importing: imported, against: existing)

        #expect(first == second)
        #expect(first.rows.map(\.outcome) == [.unchanged])
        #expect(first.createRows.isEmpty)
    }

    @Test("An unambiguous normalized name is the fallback identity")
    func fallsBackToNormalizedName() {
        let imported = local(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000003"),
            name: "  Café   Tools "
        )
        let existing = local(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000004"),
            name: "CAFE Tools"
        )

        let plan = planner.plan(importing: document([imported]), against: document([existing]))

        #expect(plan.rows.map(\.outcome) == [.update])
        #expect(plan.rows.first?.issues.isEmpty == true)
    }

    @Test("A partial local update preserves conversation history known only by the app")
    func partialLocalUpdatePreservesExistingConversationHistory() throws {
        let workspaceID = UUID(uuidString: "71000000-0000-0000-0000-000000000007")!
        let conversationID = UUID(uuidString: "72000000-0000-0000-0000-000000000007")!
        let conversation = try #require(UniConnectLocalAgentConversation(
            id: conversationID,
            kind: .codex,
            sessionID: "codex-existing-history",
            firstSeenAt: 1
        ))
        var record = UniConnectLocalWindowRecord(
            id: UUID(uuidString: "73000000-0000-0000-0000-000000000007")!,
            visibleName: "Shell",
            boxRoot: "/repo",
            workingDirectory: "/repo/api",
            conversations: [conversation],
            latestConversationID: conversationID,
            createdAt: 1,
            updatedAt: 2
        )
        _ = record.transitionToShell(at: 2)
        var existing = local(id: workspaceID, name: "Old workspace name")
        existing.cwd = "/repo"
        existing.windows[0].cwd = "/repo/api"
        existing.windows[0].localWindow = record

        var imported = local(id: workspaceID, name: "New workspace name")
        imported.cwd = "/repo"
        imported.windows[0].cwd = "/repo/api"
        imported.windows[0].localWindow = nil

        let plan = planner.plan(
            importing: document([imported]),
            against: document([existing])
        )
        let mutationWorkspace = try #require(plan.rows.first?.workspace)
        let retainedRecord = try #require(mutationWorkspace.windows.first?.localWindow)

        #expect(plan.rows.map(\.outcome) == [.update])
        #expect(retainedRecord.id == record.id)
        #expect(retainedRecord.conversations == [conversation])
        #expect(retainedRecord.latestConversationID == conversationID)
        #expect(retainedRecord.runtimeState == .shell)
        #expect(
            planner.plan(
                importing: document([mutationWorkspace]),
                against: document([mutationWorkspace])
            ).rows.map(\.outcome) == [.unchanged]
        )
    }

    @Test("An ambiguous normalized name blocks the document")
    func rejectsAmbiguousNameFallback() {
        let imported = local(name: "APP3")
        let existing = [local(name: " app3 "), local(name: "APP3")]

        let plan = planner.plan(importing: document([imported]), against: document(existing))

        #expect(plan.rows.map(\.outcome) == [.conflict])
        #expect(plan.rows.first?.issues.contains(.ambiguousName) == true)
        #expect(plan.hasBlockingIssues)
    }

    @Test("The APP4 duplicate UUID stays a terminal and cannot overwrite APP1")
    func resolvesDuplicateClaudeSessionUUIDFromMarkdownSafely() throws {
        let session = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let markdown = """
        ### APP4
        | Ventana | UUID | Ruta |
        | --- | --- | --- |
        | random-stuff | \(session) | ~/APP4 |
        | chats | \(session) | ~/APP4 |
        """

        let parsed = try UniConnectMarkdown.parseDetailed(markdown)
        let plan = planner.plan(importing: parsed, against: document([]))
        let issue = UniConnectImportPlan.Issue.duplicateClaudeSession(UUID(uuidString: session)!)

        #expect(parsed.document.workspaces.first?.windows.count == 2)
        #expect(plan.rows.map(\.outcome) == [.create])
        #expect(!plan.hasBlockingIssues)
        #expect(plan.rows[0].windowRows[0].issues.contains(issue))
        #expect(plan.rows[0].windowRows[1].issues.contains(issue))
        guard case .keepTerminalBecauseDuplicateAgent(kind: .claude, _, mutation: .create) =
            plan.rows[0].windowRows[1].action else {
            Issue.record("Expected the later duplicate to become a normal terminal")
            return
        }
        #expect(plan.rows[0].workspace.windows[0].claudeSession == session)
        #expect(plan.rows[0].workspace.windows[1].claudeSession == nil)
    }

    @Test("A second active Codex owner becomes a shell without losing its history")
    func resolvesDuplicateCodexOwnerWithoutDeletingHistory() throws {
        let conversationID = UUID(uuidString: "61000000-0000-0000-0000-000000000006")!
        let conversation = try #require(UniConnectLocalAgentConversation(
            id: conversationID,
            kind: .codex,
            sessionID: "codex-session-fixture",
            firstSeenAt: 1
        ))
        func window(id: UUID, name: String) -> UniConnectDocument.Window {
            .init(
                name: name,
                tmux: nil,
                claudeSession: nil,
                cwd: "/Users/test/Project",
                isPinned: nil,
                localWindow: .init(
                    id: id,
                    visibleName: name,
                    boxRoot: "/Users/test/Project",
                    runtimeState: .agent,
                    conversations: [conversation],
                    latestConversationID: conversationID,
                    activeConversationID: conversationID,
                    createdAt: 1,
                    updatedAt: 1
                )
            )
        }
        let imported = document([
            .init(
                name: "Codex box",
                kind: .local,
                color: nil,
                group: nil,
                isPinned: nil,
                cwd: "/Users/test/Project",
                connect: nil,
                windows: [
                    window(
                        id: UUID(uuidString: "62000000-0000-0000-0000-000000000006")!,
                        name: "Owner"
                    ),
                    window(
                        id: UUID(uuidString: "63000000-0000-0000-0000-000000000006")!,
                        name: "Fallback"
                    ),
                ]
            ),
        ])

        let plan = planner.plan(importing: imported, against: document([]))
        let fallback = try #require(plan.rows[0].workspace.windows[1].localWindow)

        guard case .keepTerminalBecauseDuplicateAgent(
            kind: .codex,
            sessionID: "codex-session-fixture",
            mutation: .create
        ) = plan.rows[0].windowRows[1].action else {
            Issue.record("Expected the second Codex owner to become a shell")
            return
        }
        #expect(fallback.runtimeState == .shell)
        #expect(fallback.activeConversationID == nil)
        #expect(fallback.latestConversationID == conversationID)
        #expect(fallback.conversations == [conversation])
    }

    @Test("A malformed Markdown UUID remains visible as a rejected row")
    func rejectsMalformedMarkdownUUIDWithoutDroppingIt() throws {
        let markdown = """
        ### Broken local session
        | Ventana | UUID | Ruta |
        | --- | --- | --- |
        | claude | APP4-NOT-A-UUID | ~/APP4 |
        """

        let parsed = try UniConnectMarkdown.parse(markdown)
        let plan = planner.plan(importing: parsed, against: document([]))

        #expect(parsed.workspaces.first?.windows.first?.claudeSession == "APP4-NOT-A-UUID")
        #expect(plan.rows.map(\.outcome) == [.rejected])
        #expect(plan.rows.first?.issues.contains(.invalidClaudeSession) == true)
    }

    @Test("An unsafe Markdown SSH command remains visible as a rejected row")
    func rejectsUnsafeMarkdownSSHWithoutDroppingIt() throws {
        let markdown = """
        ### Unsafe remote
        ```sh
        ssh root@host; touch /tmp/pwn
        ```
        | Ventana | tmux |
        | --- | --- |
        | shell | app |
        """

        let parsed = try UniConnectMarkdown.parse(markdown)
        let plan = planner.plan(importing: parsed, against: document([]))

        #expect(parsed.workspaces.first?.connect == "ssh root@host; touch /tmp/pwn")
        #expect(plan.rows.map(\.outcome) == [.rejected])
        #expect(plan.rows.first?.issues.contains(.invalidSSHConnection) == true)
    }

    @Test("A duplicate tmux target conflicts only on the same SSH host")
    func conflictsDuplicateTmuxTargetPerHost() {
        let imported = [
            ssh(name: "Remote A", host: "root@host-a", tmux: "app"),
            ssh(name: "Remote B", host: "root@host-a", tmux: "app"),
            ssh(name: "Remote C", host: "root@host-b", tmux: "app"),
        ]

        let plan = planner.plan(importing: document(imported), against: document([]))

        #expect(plan.rows.map(\.outcome) == [.conflict, .conflict, .create])
        #expect(plan.rows[0].issues.contains(.duplicateTmuxTarget(host: "root@host-a#22", session: "app")))
        #expect(plan.rows[1].issues.contains(.duplicateTmuxTarget(host: "root@host-a#22", session: "app")))
        #expect(!plan.canUseCreateOnlyExecutor)
    }

    @Test("Canonical SSH ownership normalizes host spelling and bracketed IPv6")
    func canonicalizesTmuxEndpointSpellings() {
        var dotted = ssh(name: "Dotted", host: "root@HOST-A.", tmux: "app")
        var normalized = ssh(name: "Normalized", host: "root@host-a", tmux: "app")
        var bracketedIPv6 = ssh(name: "Bracketed IPv6", host: "root@[2001:DB8::1]", tmux: "worker")
        var rawIPv6 = ssh(name: "Raw IPv6", host: "root@2001:db8::1", tmux: "worker")
        dotted.id = UUID(uuidString: "81000000-0000-0000-0000-000000000001")
        normalized.id = UUID(uuidString: "81000000-0000-0000-0000-000000000002")
        bracketedIPv6.id = UUID(uuidString: "81000000-0000-0000-0000-000000000003")
        rawIPv6.id = UUID(uuidString: "81000000-0000-0000-0000-000000000004")

        let plan = planner.plan(
            importing: document([dotted, normalized, bracketedIPv6, rawIPv6]),
            against: document([])
        )

        #expect(plan.rows.map(\.outcome) == [.conflict, .conflict, .conflict, .conflict])
        #expect(plan.rows[0].issues.contains(
            .duplicateTmuxTarget(host: "root@host-a#22", session: "app")
        ))
        #expect(plan.rows[2].issues.contains(
            .duplicateTmuxTarget(host: "root@[2001:db8::1]#22", session: "worker")
        ))
    }

    @Test("Canonical SSH ownership keeps user and port as endpoint dimensions")
    func distinguishesTmuxTargetsByUserAndPort() {
        var root = ssh(name: "Root", host: "root@host-a", tmux: "app")
        var deploy = ssh(name: "Deploy", host: "deploy@host-a", tmux: "app")
        var alternatePort = ssh(name: "Alternate port", host: "root@host-a", tmux: "app")
        root.id = UUID(uuidString: "82000000-0000-0000-0000-000000000001")
        deploy.id = UUID(uuidString: "82000000-0000-0000-0000-000000000002")
        alternatePort.id = UUID(uuidString: "82000000-0000-0000-0000-000000000003")
        alternatePort.connect = "ssh -p 2222 root@host-a"

        let plan = planner.plan(
            importing: document([root, deploy, alternatePort]),
            against: document([])
        )

        #expect(plan.rows.map(\.outcome) == [.create, .create, .create])
    }

    @Test("Endpoint migration matches tmux across the old endpoint and forces attach-only")
    func endpointMigrationIsAttachOnly() throws {
        let workspaceID = UUID(uuidString: "83000000-0000-0000-0000-000000000001")!
        var existing = ssh(name: "Remote", host: "ops@old.example.test", tmux: "worker_1")
        existing.id = workspaceID
        existing.windows[0].name = "Old title"
        var imported = ssh(name: "Remote", host: "ops@new.example.test", tmux: "worker_1")
        imported.id = workspaceID
        imported.windows[0].name = "New title"
        var sourceMap = UniConnectImportSourceMap.empty
        sourceMap.tmuxPolicies[.init(workspaceIndex: 0, windowIndex: 0)] = .createIfMissing

        let prepared = planner.prepare(
            importing: document([imported]),
            against: document([existing]),
            sourceMap: sourceMap
        )
        let window = try #require(prepared.plan.rows.first?.windowRows.first)

        #expect(window.existingWindowIndex == 0)
        #expect(window.tmuxPolicy == .attachExisting)
        guard case .update(.attachExistingTmux(session: "worker_1")) = window.action else {
            Issue.record("Endpoint migration must never create the remote tmux session")
            return
        }
        let requirements = try prepared.existingTmuxRequirements(
            for: .allMutations(in: prepared.plan)
        )
        #expect(requirements.count == 1)
        #expect(requirements[0].invocation.arguments.contains("ops@new.example.test"))
        #expect(requirements[0].invocation.arguments.last == "tmux has-session -t 'worker_1'")
    }

    @Test("A tmux target matches an existing SSH workspace before its name")
    func matchesExistingTmuxTargetBeforeName() {
        let existing = ssh(name: "Old remote name", host: "root@host-a", tmux: "app")
        let imported = ssh(name: "New remote name", host: "root@host-a", tmux: "app")

        let plan = planner.plan(importing: document([imported]), against: document([existing]))

        #expect(plan.rows.map(\.outcome) == [.update])
        #expect(plan.createRows.isEmpty)
    }

    @Test("Duplicate workspace UUIDs and normalized names never silently deduplicate")
    func conflictsDuplicateWorkspaceIdentityAndName() {
        let id = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let imported = [local(id: id, name: "APP5"), local(id: id, name: " app5 ")]

        let plan = planner.plan(importing: document(imported), against: document([]))

        #expect(plan.rows.map(\.outcome) == [.conflict, .conflict])
        #expect(plan.rows.allSatisfy { $0.issues.contains(.duplicateWorkspaceIdentifier(id)) })
        #expect(plan.rows.allSatisfy { $0.issues.contains(.duplicateWorkspaceName) })
    }

    @Test("Unsafe connections and incomplete SSH rows are rejected before apply")
    func rejectsInvalidSSHRows() {
        var unsafe = ssh(name: "Unsafe", host: "root@host", tmux: "app")
        unsafe.connect = "ssh root@host; touch /tmp/pwn"
        var missingTmux = ssh(name: "Missing tmux", host: "root@other", tmux: "app")
        missingTmux.windows[0].tmux = nil

        let plan = planner.plan(importing: document([unsafe, missingTmux]), against: document([]))

        #expect(plan.rows.map(\.outcome) == [.rejected, .rejected])
        #expect(plan.rows[0].issues.contains(.invalidSSHConnection))
        #expect(plan.rows[1].issues.contains(.sshWindowMissingTmux))
        #expect(plan.hasBlockingIssues)
        #expect(!plan.canUseCreateOnlyExecutor)
    }

    @Test("CONNECT import rejects executable paths that only look like SSH")
    func rejectsUntrustedSSHExecutablePathsBeforeApply() {
        var directPath = ssh(name: "Untrusted SSH path", host: "root@host-a", tmux: "app-a")
        directPath.connect = "/tmp/ssh root@host-a"
        var wrapperPath = ssh(name: "Untrusted wrapper path", host: "root@host-b", tmux: "app-b")
        wrapperPath.connect = "/tmp/sshpass -p fixture ssh root@host-b"
        var nestedPath = ssh(name: "Untrusted nested path", host: "root@host-c", tmux: "app-c")
        nestedPath.connect = "sshpass -p fixture /tmp/ssh root@host-c"

        let plan = planner.plan(
            importing: document([directPath, wrapperPath, nestedPath]),
            against: document([])
        )

        #expect(plan.rows.map(\.outcome) == [.rejected, .rejected, .rejected])
        #expect(plan.rows.allSatisfy { $0.issues.contains(.invalidSSHConnection) })
        #expect(plan.createRows.isEmpty)
        #expect(plan.hasBlockingIssues)
    }

    @Test("A pinned workspace cannot be silently dropped from its requested group")
    func rejectsPinnedGroupedWorkspace() {
        var imported = local(name: "Pinned member")
        imported.isPinned = true
        imported.group = "Production"

        let plan = planner.plan(importing: document([imported]), against: document([]))

        #expect(plan.rows.map(\.outcome) == [.rejected])
        #expect(plan.rows.first?.issues.contains(.pinnedWorkspaceHasGroup) == true)
    }

    @Test("Conflicting stable identities never fall back to a convenient name")
    func conflictsCrossedStableIdentities() {
        let firstSession = "10000000-0000-0000-0000-000000000001"
        let secondSession = "20000000-0000-0000-0000-000000000002"
        let existing = [
            local(name: "First", session: firstSession),
            local(name: "Second", session: secondSession),
        ]
        var imported = local(name: "First", session: firstSession)
        imported.windows.append(window(session: secondSession))

        let plan = planner.plan(importing: document([imported]), against: document(existing))

        #expect(plan.rows.map(\.outcome) == [.conflict])
        #expect(plan.rows.first?.issues.contains(.ambiguousStableIdentity) == true)
    }

    private func document(_ workspaces: [UniConnectDocument.Workspace]) -> UniConnectDocument {
        UniConnectDocument(workspaces: workspaces, savedAt: Date(timeIntervalSince1970: 0))
    }

    private func local(
        id: UUID? = nil,
        name: String,
        session: String? = nil
    ) -> UniConnectDocument.Workspace {
        UniConnectDocument.Workspace(
            id: id,
            name: name,
            kind: .local,
            color: nil,
            group: nil,
            isPinned: nil,
            cwd: nil,
            connect: nil,
            windows: session.map { [window(session: $0)] } ?? [
                UniConnectDocument.Window(
                    name: "shell",
                    tmux: nil,
                    claudeSession: nil,
                    cwd: nil,
                    isPinned: nil
                ),
            ]
        )
    }

    private func ssh(name: String, host: String, tmux: String) -> UniConnectDocument.Workspace {
        UniConnectDocument.Workspace(
            name: name,
            kind: .ssh,
            color: nil,
            group: nil,
            isPinned: nil,
            cwd: nil,
            connect: "ssh \(host)",
            windows: [
                UniConnectDocument.Window(
                    name: "terminal",
                    tmux: tmux,
                    claudeSession: nil,
                    cwd: nil,
                    isPinned: nil
                ),
            ]
        )
    }

    private func window(session: String) -> UniConnectDocument.Window {
        UniConnectDocument.Window(
            name: "claude",
            tmux: nil,
            claudeSession: session,
            cwd: nil,
            isPinned: nil
        )
    }
}
