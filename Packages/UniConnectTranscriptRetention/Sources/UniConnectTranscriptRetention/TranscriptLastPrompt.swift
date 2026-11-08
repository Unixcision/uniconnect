public import Foundation

/// When the person last wrote to an AI conversation, read from the end of its transcript
/// (`contracts/recent-prompts-v1`). Only the time leaves this type, never the text.
///
/// Only what the person typed counts: Claude's `type: "user"` entries with text (no
/// `tool_result`, no internal command or meta entries, no subagent sidechains) and Codex's
/// `user_message` events. Reads only the file's tail, growing it while no prompt is found, up to
/// ``maximumTailBytes``.
///
/// ```swift
/// let at = TranscriptLastPrompt(provider: .claude).lastPromptDate(inFileAt: transcriptURL)
/// ```
public struct TranscriptLastPrompt: Sendable {
    /// The transcript format.
    public enum Provider: String, Sendable {
        /// Claude Code: `~/.claude/projects/<folder>/<id>.jsonl`.
        case claude
        /// Codex: `~/.codex/sessions/…/rollout-<time>-<id>.jsonl`.
        case codex
    }

    /// The format read.
    public let provider: Provider
    /// The largest tail read when looking for the last prompt.
    public let maximumTailBytes: Int

    /// - Parameters:
    ///   - provider: The transcript format.
    ///   - maximumTailBytes: How far back from the end to look at most (default 4 MiB).
    public init(provider: Provider, maximumTailBytes: Int = 4 * 1_024 * 1_024) {
        self.provider = provider
        self.maximumTailBytes = maximumTailBytes
    }

    /// The time of the last prompt in the file at `url`, or `nil` when it has none or cannot be read.
    public func lastPromptDate(inFileAt url: URL) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        var tail = 64 * 1_024
        while true {
            let length = UInt64(min(UInt64(tail), size))
            guard (try? handle.seek(toOffset: size - length)) != nil,
                  let data = try? handle.read(upToCount: Int(length)) else { return nil }
            // Unless the whole file was read, the first line may be cut: it is not trusted.
            if let date = lastPromptDate(inLines: data, startsMidLine: length < size) { return date }
            if length >= size || tail >= maximumTailBytes { return nil }
            tail = min(tail * 4, maximumTailBytes)
        }
    }

    /// The time of the last prompt in JSON Lines `data`, or `nil`.
    ///
    /// - Parameter startsMidLine: Whether `data` may begin in the middle of a line, which is
    ///   then skipped.
    public func lastPromptDate(inLines data: Data, startsMidLine: Bool = false) -> Date? {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if startsMidLine, !lines.isEmpty { lines.removeFirst() }
        for line in lines.reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  isPrompt(object),
                  let stamp = object["timestamp"] as? String,
                  let date = Self.date(stamp) else { continue }
            return date
        }
        return nil
    }

    private func isPrompt(_ entry: [String: Any]) -> Bool {
        switch provider {
        case .claude:
            guard entry["type"] as? String == "user",
                  entry["isMeta"] as? Bool != true, entry["isSidechain"] as? Bool != true,
                  let message = entry["message"] as? [String: Any] else { return false }
            if let text = message["content"] as? String { return Self.isTyped(text) }
            guard let blocks = message["content"] as? [[String: Any]] else { return false }
            // A tool's answer travels as a user entry too; only text the person wrote counts.
            guard !blocks.contains(where: { $0["type"] as? String == "tool_result" }) else { return false }
            return blocks.contains { block in
                block["type"] as? String == "text" && (block["text"] as? String).map(Self.isTyped) == true
            }
        case .codex:
            guard entry["type"] as? String == "event_msg",
                  let payload = entry["payload"] as? [String: Any] else { return false }
            return payload["type"] as? String == "user_message"
        }
    }

    /// Text the person typed, not what Claude Code injects for its own commands.
    private static func isTyped(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !internalPrefixes.contains { trimmed.hasPrefix($0) }
    }

    private static let internalPrefixes = [
        "<command-name>", "<command-message>", "<command-args>", "<local-command-stdout>",
        "<local-command-stderr>", "<local-command-caveat>", "Caveat: The messages below were generated",
        "[Request interrupted by user", "<user-memory-input>", "<bash-input>", "<bash-stdout>", "<bash-stderr>",
    ]

    private static func date(_ stamp: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: stamp) { return date }
        return ISO8601DateFormatter().date(from: stamp)
    }
}
