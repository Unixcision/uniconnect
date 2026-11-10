import Foundation
import SQLite3

/// Reads Codex's `threads` table, read-only, from the highest `state_<n>.sqlite` of a `CODEX_HOME`.
///
/// Opened with `mode=ro`: UniConnect never writes Codex's state. Columns that an older Codex lacks
/// are read as absent, which makes its rows fail ``AgentCodexThread/isTerminalConversation`` rather
/// than guess.
///
/// ```swift
/// let store = AgentCodexThreadStore(codexHome: home.appendingPathComponent(".codex"))
/// store.threads(workingDirectories: ["/Users/d/proyecto"])
/// ```
public struct AgentCodexThreadStore: Sendable {
    /// The Codex home (`$CODEX_HOME` or `~/.codex`).
    public let codexHome: URL
    /// The most rows read for one call.
    public let maximumRows: Int

    /// Creates a reader.
    ///
    /// - Parameters:
    ///   - codexHome: The Codex home folder.
    ///   - maximumRows: The most rows read per call.
    public init(codexHome: URL, maximumRows: Int = 256) {
        self.codexHome = codexHome
        self.maximumRows = maximumRows
    }

    /// The `state_<n>.sqlite` with the highest `n`, or `nil` when there is none.
    public var database: URL? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: codexHome.path) else { return nil }
        let versions = names.compactMap { name -> (Int, String)? in
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite"),
                  let number = Int(name.dropFirst("state_".count).dropLast(".sqlite".count)) else { return nil }
            return (number, name)
        }
        return versions.max { $0.0 < $1.0 }.map { codexHome.appendingPathComponent($0.1, isDirectory: false) }
    }

    /// The threads whose folder is one of `workingDirectories`.
    ///
    /// - Parameter workingDirectories: Folders to look for, as given and resolved.
    /// - Returns: The rows, newest change first; empty when the database cannot be read.
    public func threads(workingDirectories: [String]) -> [AgentCodexThread] {
        let folders = Array(Set(workingDirectories.filter { $0.hasPrefix("/") }))
        guard !folders.isEmpty, let database else { return [] }
        var components = URLComponents()
        components.scheme = "file"
        components.path = database.path
        components.queryItems = [URLQueryItem(name: "mode", value: "ro")]
        guard let uri = components.string else { return [] }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            return []
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 500)

        let columns = columnNames(handle)
        guard columns.isSuperset(of: ["id", "cwd", "updated_at", "created_at", "archived"]) else { return [] }
        let created = columns.contains("created_at_ms") ? "coalesce(created_at_ms, created_at * 1000)" : "created_at * 1000"
        let updated = columns.contains("updated_at_ms") ? "coalesce(updated_at_ms, updated_at * 1000)" : "updated_at * 1000"
        let originator = columns.contains("originator") ? "originator" : "NULL"
        let source = columns.contains("thread_source") ? "thread_source" : "NULL"
        let marks = folders.map { _ in "?" }.joined(separator: ",")
        let sql = "SELECT id, cwd, \(created), \(updated), \(originator), archived, \(source) FROM threads "
            + "WHERE cwd IN (\(marks)) ORDER BY \(updated) DESC LIMIT \(maximumRows)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, folder) in folders.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), folder, -1, transient)
        }
        var rows: [AgentCodexThread] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(statement, 0), let cwd = text(statement, 1) else { continue }
            rows.append(AgentCodexThread(
                id: id, workingDirectory: cwd,
                createdAtMilliseconds: sqlite3_column_int64(statement, 2),
                updatedAtMilliseconds: sqlite3_column_int64(statement, 3),
                originator: text(statement, 4),
                archived: sqlite3_column_int64(statement, 5) != 0,
                threadSource: text(statement, 6)
            ))
        }
        return rows
    }

    private func columnNames(_ handle: OpaquePointer) -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA table_info(threads)", -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = text(statement, 1) { names.insert(name) }
        }
        return names
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }
}
