public import Foundation

/// The conversations of the Claude Code processes alive right now.
///
/// Claude writes `~/.claude/sessions/<pid>.json` with the `sessionId` it is writing to. A file
/// whose process is gone is stale and does not protect anything.
public struct ClaudeLiveSessionReader: Sendable {
    private let directory: URL
    private let isAlive: @Sendable (Int32) -> Bool

    /// Creates a reader.
    /// - Parameters:
    ///   - directory: `~/.claude/sessions` of the user the AIs run as.
    ///   - isAlive: whether a process exists; defaults to `kill(pid, 0)`.
    public init(directory: URL, isAlive: @escaping @Sendable (Int32) -> Bool = { pid in kill(pid, 0) == 0 || errno == EPERM }) {
        self.directory = directory
        self.isAlive = isAlive
    }

    /// The conversation ids of live Claude processes, lower-cased.
    public func conversationIDs() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var ids = Set<String>()
        for name in names where name.hasSuffix(".json") {
            guard let pid = Int32(name.dropLast(".json".count)), isAlive(pid),
                  let data = FileManager.default.contents(atPath: directory.appendingPathComponent(name).path),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["sessionId"] as? String, !id.isEmpty else { continue }
            ids.insert(id.lowercased())
        }
        return ids
    }
}
