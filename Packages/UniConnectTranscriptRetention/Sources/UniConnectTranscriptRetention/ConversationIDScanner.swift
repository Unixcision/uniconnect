/// Finds conversation ids (UUIDs) in a path or a document, in lower case.
///
/// Claude names a conversation `<uuid>.jsonl` and its subagents `<uuid>/subagents/…`; Codex ends
/// the file name with it (`rollout-<time>-<uuid>.jsonl`). Any UUID in a path is therefore enough
/// to tell which conversation the file belongs to, and any UUID in UniConnect's state is enough
/// to protect one: the ones that are not conversations never match a transcript.
public struct ConversationIDScanner: Sendable {
    /// Creates a scanner.
    public init() {}

    /// Every UUID in `text`, lower-cased.
    public func ids(in text: String) -> Set<String> {
        let pattern = #/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/#
        return Set(text.matches(of: pattern).map { String($0.output).lowercased() })
    }
}
