import Foundation
import UniConnectTranscriptRetention

/// `last_prompt_at` of each window for the phone (`contracts/recent-prompts-v1`): when the person
/// last wrote to the window's current AI conversation, read from its transcript.
///
/// Built into every `mobile.workspace.list`, so it is cheap on repeat: a transcript is found once
/// per conversation, and re-read only when its modification time or size changed. Only the time
/// is kept, never the text.
@MainActor
final class MobileLastPromptIndex {
    private struct Stamp: Equatable {
        let modified: Date
        let size: Int
    }

    private let homeDirectory: URL
    private let read: (TranscriptLastPrompt.Provider, URL) -> Date?
    private let fileManager: FileManager
    private var paths: [String: URL] = [:]
    private var missingSince: [String: Date] = [:]
    private var cached: [URL: (stamp: Stamp, date: Date?)] = [:]

    /// - Parameters:
    ///   - homeDirectory: Where `.claude/projects` and `.codex/sessions` live; tests pass a fixture.
    ///   - fileManager: Lists and stats transcripts.
    ///   - read: Reads a transcript's last prompt; tests count its calls.
    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        read: @escaping (TranscriptLastPrompt.Provider, URL) -> Date? = { provider, url in
            TranscriptLastPrompt(provider: provider).lastPromptDate(inFileAt: url)
        }
    ) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
        self.read = read
    }

    /// Seconds since the epoch of the last prompt of `conversation`, or `nil` when it has none.
    func lastPromptAt(_ conversation: UniConnectLocalAgentConversation?) -> TimeInterval? {
        guard let conversation else { return nil }
        let provider: TranscriptLastPrompt.Provider
        switch conversation.kind {
        case .claude: provider = .claude
        case .codex: provider = .codex
        default: return nil
        }
        guard let url = transcript(provider: provider, sessionID: conversation.sessionID.lowercased()),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              let size = (attributes[.size] as? NSNumber)?.intValue else { return nil }
        let stamp = Stamp(modified: modified, size: size)
        if let hit = cached[url], hit.stamp == stamp { return hit.date?.timeIntervalSince1970 }
        let date = read(provider, url)
        cached[url] = (stamp, date)
        return date?.timeIntervalSince1970
    }

    /// Where a conversation's transcript is; looked up once, and a miss is retried after a minute.
    private func transcript(provider: TranscriptLastPrompt.Provider, sessionID: String) -> URL? {
        let key = provider.rawValue + ":" + sessionID
        if let known = paths[key], fileManager.fileExists(atPath: known.path) { return known }
        if let since = missingSince[key], Date().timeIntervalSince(since) < 60 { return nil }
        let found: URL?
        switch provider {
        case .claude:
            let projects = homeDirectory.appendingPathComponent(".claude/projects", isDirectory: true)
            let folders = (try? fileManager.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
            found = folders.lazy
                .map { $0.appendingPathComponent(sessionID + ".jsonl", isDirectory: false) }
                .first { self.fileManager.fileExists(atPath: $0.path) }
        case .codex:
            let sessions = homeDirectory.appendingPathComponent(".codex/sessions", isDirectory: true)
            let suffix = "-" + sessionID + ".jsonl"
            let walker = fileManager.enumerator(at: sessions, includingPropertiesForKeys: nil)
            var match: URL?
            while let next = walker?.nextObject() as? URL {
                if next.lastPathComponent.lowercased().hasSuffix(suffix) { match = next; break }
            }
            found = match
        }
        if let found {
            paths[key] = found
            missingSince[key] = nil
        } else {
            missingSince[key] = Date()
        }
        return found
    }
}
