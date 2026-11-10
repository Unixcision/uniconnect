import Foundation
import SQLite3
import Testing
@testable import CMUXAgentLaunch

/// La tabla `threads` de Codex se lee solo para leer, del `state_<n>.sqlite` más alto.
@Suite("Hilos de Codex en SQLite")
struct AgentCodexThreadStoreTests {
    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("codex-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func write(_ database: URL, _ statements: [String]) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(database.path, &handle) == SQLITE_OK, let handle else {
            Issue.record("no se pudo crear \(database.path)")
            return
        }
        defer { sqlite3_close(handle) }
        for statement in statements {
            #expect(sqlite3_exec(handle, statement, nil, nil, nil) == SQLITE_OK, Comment(rawValue: statement))
        }
    }

    @Test("Lee las filas de su carpeta del state más alto, con los campos que trae Codex 0.167")
    func readsTheHighestStateDatabase() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let schema = "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, source TEXT NOT NULL, cwd TEXT NOT NULL, archived INTEGER NOT NULL DEFAULT 0, created_at_ms INTEGER, updated_at_ms INTEGER, thread_source TEXT, originator TEXT)"
        try write(home.appendingPathComponent("state_4.sqlite"), [schema,
            "INSERT INTO threads VALUES ('viejo','',1,1,'cli','/u/p',0,1000,1000,'user','codex-tui')"])
        try write(home.appendingPathComponent("state_5.sqlite"), [schema,
            "INSERT INTO threads VALUES ('a','',1794100004,1794100060,'cli','/u/p',0,1794100004000,1794100060000,'user','codex-tui')",
            "INSERT INTO threads VALUES ('sub','',1794100030,1794100090,'{}','/u/p',0,1794100030000,1794100090000,'subagent','codex-tui')",
            "INSERT INTO threads VALUES ('otra','',1794100005,1794100200,'cli','/u/otra',0,NULL,NULL,'user','codex-tui')"])
        let store = AgentCodexThreadStore(codexHome: home)
        #expect(store.database?.lastPathComponent == "state_5.sqlite")
        let rows = store.threads(workingDirectories: ["/u/p"])
        #expect(rows.map(\.id) == ["sub", "a"])
        #expect(rows.last == AgentCodexThread(
            id: "a", workingDirectory: "/u/p", createdAtMilliseconds: 1_794_100_004_000,
            updatedAtMilliseconds: 1_794_100_060_000, originator: "codex-tui", archived: false, threadSource: "user"
        ))
        #expect(rows.first?.isTerminalConversation == false)
        // Sin las columnas _ms, los segundos por mil.
        #expect(store.threads(workingDirectories: ["/u/otra"]).first?.createdAtMilliseconds == 1_794_100_005_000)
    }

    @Test("Un Codex antiguo sin originator no da hilos de terminal, y sin base no hay filas")
    func olderSchemaAndMissingDatabase() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(AgentCodexThreadStore(codexHome: home).threads(workingDirectories: ["/u/p"]).isEmpty)
        try write(home.appendingPathComponent("state_3.sqlite"), [
            "CREATE TABLE threads (id TEXT PRIMARY KEY, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, cwd TEXT NOT NULL, archived INTEGER NOT NULL DEFAULT 0)",
            "INSERT INTO threads VALUES ('x',1,2,'/u/p',0)",
        ])
        let rows = AgentCodexThreadStore(codexHome: home).threads(workingDirectories: ["/u/p"])
        #expect(rows.count == 1)
        #expect(rows.first?.isTerminalConversation == false)
    }
}
