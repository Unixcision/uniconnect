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

    @Test("An ambiguous normalized name blocks the document")
    func rejectsAmbiguousNameFallback() {
        let imported = local(name: "APP3")
        let existing = [local(name: " app3 "), local(name: "APP3")]

        let plan = planner.plan(importing: document([imported]), against: document(existing))

        #expect(plan.rows.map(\.outcome) == [.conflict])
        #expect(plan.rows.first?.issues.contains(.ambiguousName) == true)
        #expect(plan.hasBlockingIssues)
    }

    @Test("The APP4 duplicate terminal UUID is retained and conflicts its workspace")
    func conflictsDuplicateClaudeSessionUUIDFromMarkdown() throws {
        let session = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let markdown = """
        ### APP4
        | Ventana | UUID | Ruta |
        | --- | --- | --- |
        | random-stuff | \(session) | ~/APP4 |
        | chats | \(session) | ~/APP4 |
        """

        let parsed = try UniConnectMarkdown.parse(markdown)
        let plan = planner.plan(importing: parsed, against: document([]))
        let issue = UniConnectImportPlan.Issue.duplicateClaudeSession(UUID(uuidString: session)!)

        #expect(parsed.workspaces.first?.windows.count == 2)
        #expect(plan.rows.map(\.outcome) == [.conflict])
        #expect(plan.rows.allSatisfy { $0.issues.contains(issue) })
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
