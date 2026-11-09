import Foundation

/// How big a Claude conversation is, read from the last `usage` of its `.jsonl` transcript.
///
/// The size is what a post-reopen message costs: the agent rereads the whole context to answer
/// it. It is `input_tokens + cache_creation_input_tokens + cache_read_input_tokens` of the most
/// recent main-thread assistant turn (sub-agent turns, `isSidechain: true`, are not the
/// conversation's context). Read from the end, because transcripts grow to hundreds of megabytes.
public struct ClaudeConversationUsage: Sendable, Equatable {
    /// How much of the end of a transcript is read: enough for a few long turns.
    public static let tailBytes = 4 * 1024 * 1024

    /// The conversation's context in tokens.
    public let contextTokens: Int

    /// Reads the last usage out of the end of a transcript.
    ///
    /// - Parameter tail: The last bytes of a `.jsonl` file; a partial first line is ignored.
    /// - Returns: `nil` when no main-thread usage is found.
    public init?(tail: Data) {
        let lines = tail.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard line.range(of: Data("\"usage\"".utf8)) != nil,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  (object["isSidechain"] as? Bool) != true,
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }
            let keys = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
            let values = keys.compactMap { (usage[$0] as? NSNumber)?.intValue }
            guard !values.isEmpty else { continue }
            contextTokens = values.reduce(0, +)
            return
        }
        return nil
    }

    /// Reads a transcript file's tail.
    ///
    /// - Parameter url: The conversation's `.jsonl`.
    /// - Returns: `nil` when the file cannot be read or has no usage.
    public init?(contentsOf url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(Self.tailBytes) ? size - UInt64(Self.tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd() else { return nil }
        self.init(tail: data)
    }

    /// Where Claude keeps a conversation's transcript: `<config>/projects/<cwd>/<id>.jsonl`, with
    /// every character of the folder that is not a letter or digit turned into `-`.
    ///
    /// - Parameters:
    ///   - configRoot: The Claude configuration folder (`~/.claude` or `CLAUDE_CONFIG_DIR`).
    ///   - workingDirectory: The folder the conversation runs in.
    ///   - sessionID: The conversation id.
    /// - Returns: The transcript's expected location.
    public static func transcriptURL(configRoot: URL, workingDirectory: String, sessionID: String) -> URL {
        let folder = String(workingDirectory.unicodeScalars.map { scalar -> Character in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9": Character(scalar)
            default: "-"
            }
        })
        return configRoot
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent(sessionID + ".jsonl", isDirectory: false)
    }
}
