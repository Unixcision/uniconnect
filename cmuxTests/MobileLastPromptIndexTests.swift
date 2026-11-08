import Foundation
import Testing
import UniConnectTranscriptRetention

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `recent-prompts.v1` on the Mac: the window's conversation finds its transcript, and a transcript
/// is read again only when it changed.
@MainActor
@Suite(.serialized)
struct MobileLastPromptIndexTests {
    private let home: URL
    private let sessionID = "6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b"

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("UniConnectLastPrompt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude/projects/-srv-app", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    private func conversation(_ kind: RestorableAgentKind) throws -> UniConnectLocalAgentConversation {
        try #require(UniConnectLocalAgentConversation(snapshot: SessionRestorableAgentSnapshot(
            kind: kind, sessionId: sessionID, workingDirectory: "/srv/app", launchCommand: nil
        )))
    }

    @Test("Reads the last prompt of the window's Claude conversation, and only again when it changed")
    func cachesByModificationAndSize() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let transcript = home.appendingPathComponent(".claude/projects/-srv-app/\(sessionID).jsonl")
        let first = #"{"type":"user","message":{"role":"user","content":"hola"},"timestamp":"2026-11-08T10:00:00.000Z"}"# + "\n"
        try Data(first.utf8).write(to: transcript)
        var reads = 0
        let index = MobileLastPromptIndex(homeDirectory: home) { provider, url in
            reads += 1
            return TranscriptLastPrompt(provider: provider).lastPromptDate(inFileAt: url)
        }
        let claude = try conversation(.claude)
        let expected = try #require(ISO8601DateFormatter().date(from: "2026-11-08T10:00:00Z")).timeIntervalSince1970
        #expect(index.lastPromptAt(claude) == expected)
        #expect(index.lastPromptAt(claude) == expected)
        #expect(reads == 1)

        let second = first + #"{"type":"user","message":{"role":"user","content":"otra"},"timestamp":"2026-11-08T10:30:00.000Z"}"# + "\n"
        try Data(second.utf8).write(to: transcript)
        let later = try #require(ISO8601DateFormatter().date(from: "2026-11-08T10:30:00Z")).timeIntervalSince1970
        #expect(index.lastPromptAt(claude) == later)
        #expect(reads == 2)
    }

    @Test("No conversation, or one without a transcript: null")
    func nothingWithoutConversation() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let index = MobileLastPromptIndex(homeDirectory: home)
        #expect(index.lastPromptAt(nil) == nil)
        #expect(index.lastPromptAt(try conversation(.claude)) == nil)
        #expect(index.lastPromptAt(try conversation(.codex)) == nil)
    }

    @Test("Codex: finds the rollout by its conversation id")
    func codexRollout() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let day = home.appendingPathComponent(".codex/sessions/2026/11/08", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let rollout = day.appendingPathComponent("rollout-2026-11-08T09-00-00-\(sessionID).jsonl")
        let text = #"{"timestamp":"2026-11-08T09:01:00.000Z","type":"event_msg","payload":{"type":"user_message","message":"revisa"}}"# + "\n"
        try Data(text.utf8).write(to: rollout)
        let index = MobileLastPromptIndex(homeDirectory: home)
        let expected = try #require(ISO8601DateFormatter().date(from: "2026-11-08T09:01:00Z")).timeIntervalSince1970
        #expect(index.lastPromptAt(try conversation(.codex)) == expected)
    }
}
