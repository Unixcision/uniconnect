import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("UniConnect detailed CONNECT parser")
struct UniConnectMarkdownDetailedTests {
    @Test("Real-world local headers retain every name, UUID, path, and source line")
    func parsesHumanLocalTable() throws {
        let first = "11111111-1111-1111-1111-111111111111"
        let second = "22222222-2222-2222-2222-222222222222"
        let markdown = """
        # CONNECT
        ## 2. Cajas LOCALES
        ### 2.1 · Caja "Example Apps" — 2 ventanas
        | Ventana | UUID de sesión | Ruta de arranque |
        |---------|----------------|------------------|
        | APP 1 | `\(first)` | `~/Projects/One` |
        | APP 2 | `\(second)` | `~/Projects/Two` ⚠️ |
        ```bash
        # APP 1
        cd ~/Projects/One && claude --dangerously-skip-permissions --resume \(first)
        # APP 2
        cd ~/Projects/Two && claude --dangerously-skip-permissions --resume \(second)
        ```
        """

        let parsed = try UniConnectMarkdown.parseDetailed(markdown)
        let workspace = try #require(parsed.document.workspaces.first)

        #expect(workspace.kind == .local)
        #expect(workspace.name == "Example Apps")
        #expect(workspace.windows.map(\.name) == ["APP 1", "APP 2"])
        #expect(workspace.windows.map(\.claudeSession) == [first, second])
        #expect(workspace.windows[0].cwd?.hasSuffix("/Projects/One") == true)
        #expect(workspace.windows[1].cwd?.hasSuffix("/Projects/Two") == true)
        #expect(parsed.sourceMap.workspaceLocations[0]?.line == 3)
        #expect(parsed.sourceMap.windowLocations[.init(workspaceIndex: 0, windowIndex: 0)]?.line == 6)
        #expect(parsed.sourceMap.windowLocations[.init(workspaceIndex: 0, windowIndex: 1)]?.line == 7)
    }

    @Test("Existing and new tmux declarations keep distinct safe policies")
    func parsesTmuxPolicies() throws {
        let markdown = """
        # CONNECT
        ## 3. Cajas SSH
        ### 3.1 · Existing remote — 2 tmux EXISTENTES (no crear nuevos)
        ```bash
        ssh ops@example.test
        ```
        | # | tmux |
        |---|------|
        | 1 | `worker_a` |
        | 2 | `worker_b` |

        ### 3.2 · New remote — tmux a CREAR
        ```bash
        ssh deploy@example.test
        ```
        | # | tmux a crear |
        |---|--------------|
        | 1 | `new_worker` |
        """

        let parsed = try UniConnectMarkdown.parseDetailed(markdown)
        let existingKey = UniConnectImportSourceMap.WindowKey(workspaceIndex: 0, windowIndex: 0)
        let newKey = UniConnectImportSourceMap.WindowKey(workspaceIndex: 1, windowIndex: 0)

        #expect(parsed.document.workspaces.map(\.kind) == [.ssh, .ssh])
        #expect(parsed.document.workspaces[0].windows.map(\.tmux) == ["worker_a", "worker_b"])
        #expect(parsed.sourceMap.tmuxPolicies[existingKey] == .attachExisting)
        #expect(parsed.sourceMap.tmuxPolicies[newKey] == .createIfMissing)

        let plan = UniConnectImportPlanner().plan(
            importing: parsed,
            against: UniConnectDocument(workspaces: [], savedAt: Date(timeIntervalSince1970: 0))
        )
        guard case .create(.attachExistingTmux(session: "worker_a")) =
            plan.rows[0].windowRows[0].action else {
            Issue.record("An existing declaration must be attach-only")
            return
        }
        guard case .create(.createTmuxIfMissing(session: "new_worker")) =
            plan.rows[1].windowRows[0].action else {
            Issue.record("An explicitly new declaration may create its tmux session")
            return
        }
    }

    @Test("Malformed window rows remain visible with a precise source diagnostic")
    func retainsInvalidTableDeclaration() throws {
        let markdown = """
        ## Cajas LOCALES
        ### Broken box
        | Ventana | UUID | Ruta |
        |---|---|---|
        | BROKEN | | ~/Projects/Broken |
        """

        let parsed = try UniConnectMarkdown.parseDetailed(markdown)
        let plan = UniConnectImportPlanner().plan(
            importing: parsed,
            against: UniConnectDocument(workspaces: [], savedAt: Date(timeIntervalSince1970: 0))
        )
        let window = try #require(plan.rows.first?.windowRows.first)

        #expect(parsed.document.workspaces.first?.windows.count == 1)
        #expect(window.outcome == .rejected)
        #expect(window.sourceLocation?.line == 5)
        #expect(window.issues.contains(.sourceDiagnostic(code: .windowMissingIdentity, line: 5)))
    }

    @Test("A nameless workspace heading remains visible as a rejected source row")
    func retainsNamelessWorkspaceDeclaration() throws {
        let markdown = """
        ## Local workspaces
        ###
        | Window | UUID | Directory |
        |---|---|---|
        | Terminal | | /Users/example/Project |
        """

        let parsed = try UniConnectMarkdown.parseDetailed(markdown)
        let plan = UniConnectImportPlanner().plan(
            importing: parsed,
            against: UniConnectDocument(workspaces: [], savedAt: Date(timeIntervalSince1970: 0))
        )

        #expect(parsed.document.workspaces.count == 1)
        #expect(plan.rows.count == 1)
        #expect(plan.rows[0].outcome == .rejected)
        #expect(plan.rows[0].sourceLocation?.line == 2)
        #expect(plan.rows[0].issues.contains(.sourceDiagnostic(code: .workspaceMissingName, line: 2)))
    }

    @Test("A password wrapper is never copied into the preview summary")
    func previewIsPasswordFree() throws {
        let markdown = """
        ## Cajas SSH
        ### Private remote — tmux EXISTENTE
        ```bash
        sshpass -p 'fixture-password' ssh ops@example.test
        ```
        | Ventana | tmux |
        |---|---|
        | worker | worker_1 |
        """

        let parsed = try UniConnectMarkdown.parseDetailed(markdown)
        let plan = UniConnectImportPlanner().plan(
            importing: parsed,
            against: UniConnectDocument(workspaces: [], savedAt: Date(timeIntervalSince1970: 0))
        )
        let preview = try #require(plan.rows.first?.preview)

        #expect(preview.hostLabel?.contains("fixture-password") == false)
        #expect(preview.hostLabel?.contains("ops@example.test") == true)
    }

    @Test("Reimport is idempotent and preserves the duplicate fallback as a shell")
    func duplicateFallbackIsIdempotent() throws {
        let session = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let markdown = """
        ## Cajas LOCALES
        ### Caja "APP BOX"
        | Ventana | UUID de sesión | Ruta |
        |---|---|---|
        | APP 1 | \(session) | ~/Projects/App |
        | APP 4 | \(session) | ~/Projects/App |
        """
        let parsed = try UniConnectMarkdown.parseDetailed(markdown)
        let planner = UniConnectImportPlanner()
        let empty = UniConnectDocument(workspaces: [], savedAt: Date(timeIntervalSince1970: 0))
        let first = planner.plan(importing: parsed, against: empty)
        let importedState = UniConnectDocument(
            workspaces: first.rows.map(\.workspace),
            savedAt: Date(timeIntervalSince1970: 0)
        )
        let second = planner.plan(importing: parsed, against: importedState)

        #expect(first.rows.map(\.outcome) == [.create])
        #expect(second.rows.map(\.outcome) == [.unchanged])
        #expect(second.defaultSelectedRowIDs.isEmpty)
        #expect(second.rows[0].workspace.windows[1].claudeSession == nil)
        guard case .keepTerminalBecauseDuplicateAgent(kind: .claude, _, mutation: .unchanged) =
            second.rows[0].windowRows[1].action else {
            Issue.record("APP 4 must remain the same safe shell on reimport")
            return
        }
    }

    @Test("Lossy JSON parsing preserves malformed workspaces and windows")
    func retainsMalformedJSONDeclarations() throws {
        let json = """
        {
          "version": 2,
          "app": "UniConnect",
          "savedAt": "2026-01-01T00:00:00Z",
          "workspaces": [
            "not-an-object",
            {
              "name": "Partially valid",
              "kind": "local",
              "cwd": "/Users/example/Project",
              "windows": [
                {
                  "name": "Broken window",
                  "claudeSession": 17,
                  "cwd": "/Users/example/Project"
                }
              ]
            }
          ]
        }
        """

        let parsed = try UniConnectJSONImportParser.parseDetailed(Data(json.utf8))
        let malformedWorkspace = try #require(parsed.sourceMap.diagnosticsByWorkspace[0]?.first)
        let malformedWindowKey = UniConnectImportSourceMap.WindowKey(
            workspaceIndex: 1,
            windowIndex: 0
        )
        let malformedWindow = try #require(parsed.sourceMap.diagnosticsByWindow[malformedWindowKey]?.first)

        #expect(parsed.document.workspaces.count == 2)
        #expect(parsed.document.workspaces[1].windows.count == 1)
        #expect(malformedWorkspace.code == .malformedJSONWorkspace)
        #expect(malformedWorkspace.location.section == "workspaces[0]")
        #expect(malformedWindow.code == .malformedJSONWindow)
        #expect(malformedWindow.location.section == "workspaces[1].windows[0]")

        let plan = UniConnectImportPlanner().plan(
            importing: parsed,
            against: UniConnectDocument(workspaces: [], savedAt: Date(timeIntervalSince1970: 0))
        )
        #expect(plan.rows.map(\.outcome) == [.rejected, .rejected])
    }

    @Test("Version-two JSON preserves durable local-window identity")
    func parsesVersionTwoLocalWindow() throws {
        let localWindowID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let source = UniConnectDocument(workspaces: [
            .init(
                name: "Local box",
                kind: .local,
                color: nil,
                group: nil,
                isPinned: nil,
                cwd: "/Users/example/Project",
                connect: nil,
                windows: [
                    .init(
                        name: "Terminal",
                        tmux: nil,
                        claudeSession: nil,
                        cwd: "/Users/example/Project/api",
                        isPinned: nil,
                        localWindow: .init(
                            id: localWindowID,
                            visibleName: "Terminal",
                            boxRoot: "/Users/example/Project",
                            workingDirectory: "/Users/example/Project/api",
                            createdAt: 1,
                            updatedAt: 1
                        )
                    )
                ]
            )
        ], savedAt: Date(timeIntervalSince1970: 0))
        let data = try JSONEncoder().encode(source)

        let parsed = try UniConnectJSONImportParser.parseDetailed(data)

        #expect(parsed.document.workspaces[0].windows[0].localWindow?.id == localWindowID)
        #expect(
            parsed.document.workspaces[0].windows[0].localWindow?.workingDirectory
                == "/Users/example/Project/api"
        )
        #expect(parsed.sourceMap.windowLocations[
            .init(workspaceIndex: 0, windowIndex: 0)
        ]?.section == "workspaces[0].windows[0]")
    }
}
