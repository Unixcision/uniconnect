import Foundation
import Testing
@testable import UniConnectTranscriptRetention

/// The archiver on real folders and the real `gzip`: nothing a transcript held may be lost.
@Suite struct TranscriptArchiverTests {
    private let home: URL
    private let now = Date(timeIntervalSince1970: 1_793_900_000)
    private let manager = FileManager.default

    init() throws {
        home = manager.temporaryDirectory.appendingPathComponent("transcripts-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: home, withIntermediateDirectories: true)
    }

    private var claude: URL { home.appendingPathComponent(".claude/projects", isDirectory: true) }

    private func archiver(
        protected: Set<String> = [],
        compressor: any TranscriptCompressing = GzipTranscriptCompressor()
    ) -> TranscriptArchiver {
        let now = self.now
        return TranscriptArchiver(
            roots: TranscriptRoot.aiTranscripts(home: home),
            compressor: compressor,
            protectedConversations: { protected },
            now: { now }
        )
    }

    @discardableResult
    private func write(_ relative: String, _ text: String, ageDays: Double, under root: URL? = nil) throws -> URL {
        let url = (root ?? claude).appendingPathComponent(relative)
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try manager.setAttributes([.modificationDate: now.addingTimeInterval(-ageDays * 86_400), .posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    private func gunzip(_ url: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", "--", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func date(_ url: URL) throws -> Date? {
        try manager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    @Test func aMonthOldTranscriptIsCompressedWithItsDateAndComesBackIntact() async throws {
        let text = (0..<2_000).map { "{\"n\":\($0),\"texto\":\"línea con tilde ñ\"}\n" }.joined()
        let original = try write("-Users-dani/11111111-1111-4111-8111-111111111111.jsonl", text, ageDays: 45)
        let originalDate = try date(original)

        let summary = await archiver().runOnce()

        let archive = URL(fileURLWithPath: original.path + ".gz")
        #expect(summary.compressed == 1)
        #expect(summary.bytesFreed > 0)
        #expect(!manager.fileExists(atPath: original.path))
        #expect(try gunzip(archive) == text)
        #expect(try date(archive) == originalDate)
        #expect((try manager.attributesOfItem(atPath: archive.path)[.posixPermissions] as? Int) == 0o600)
    }

    @Test func aResumedArchiveGetsTheNewPartAppendedInOrder() async throws {
        let old = try write("-Users-dani/22222222-2222-4222-8222-222222222222.jsonl", "viejo\n", ageDays: 120)
        _ = await archiver().runOnce()
        try write("-Users-dani/22222222-2222-4222-8222-222222222222.jsonl", "nuevo\n", ageDays: 40)

        let summary = await archiver().runOnce()

        #expect(summary.compressed == 1)
        #expect(try gunzip(URL(fileURLWithPath: old.path + ".gz")) == "viejo\nnuevo\n")
    }

    @Test func aTranscriptThatChangesWhileBeingCompressedIsLeftForTheNextPass() async throws {
        let original = try write("-Users-dani/33333333-3333-4333-8333-333333333333.jsonl", "antes\n", ageDays: 60)
        let summary = await archiver(compressor: AppendingWhileCompressing(original: original)).runOnce()

        #expect(summary.postponed == 1)
        #expect(String(decoding: try Data(contentsOf: original), as: UTF8.self) == "antes\nla IA volvió a escribir\n")
        #expect(!manager.fileExists(atPath: original.path + ".gz"))
        #expect(!manager.fileExists(atPath: original.path + ".gz.tmp"))
    }

    @Test func aPassCutAfterReplacingTheArchiveIsFinishedWithoutDuplicating() async throws {
        let original = try write("-Users-dani/12121212-1212-4121-8121-121212121212.jsonl", "una vez\n", ageDays: 50)
        _ = await archiver().runOnce()
        // The cut: the original is still there, with the archive's very date.
        let archive = URL(fileURLWithPath: original.path + ".gz")
        try write("-Users-dani/12121212-1212-4121-8121-121212121212.jsonl", "una vez\n", ageDays: 50)
        try manager.setAttributes([.modificationDate: try #require(try date(archive))], ofItemAtPath: original.path)

        let summary = await archiver().runOnce()

        #expect(summary.compressed == 1)
        #expect(!manager.fileExists(atPath: original.path))
        #expect(try gunzip(archive) == "una vez\n")
    }

    @Test func overAYearItIsDeletedAndItsEmptyFoldersGoButTheRootStays() async throws {
        let subagent = try write("-Users-dani-viejo/44444444-4444-4444-8444-444444444444/subagents/agent-a.jsonl", "x\n", ageDays: 400)
        try write("-Users-dani/55555555-5555-4555-8555-555555555555.jsonl.gz", "gz", ageDays: 366)

        let summary = await archiver().runOnce()

        #expect(summary.deleted == 2)
        #expect(!manager.fileExists(atPath: subagent.deletingLastPathComponent().path))
        #expect(!manager.fileExists(atPath: claude.appendingPathComponent("-Users-dani-viejo").path))
        #expect(manager.fileExists(atPath: claude.path))
    }

    @Test func aConversationInUseIsNotTouchedHoweverOld() async throws {
        let id = "66666666-6666-4666-8666-666666666666"
        let main = try write("-Users-dani/\(id).jsonl", "en uso\n", ageDays: 500)
        let subagent = try write("-Users-dani/\(id)/subagents/agent-b.jsonl", "sub\n", ageDays: 90)

        let summary = await archiver(protected: [id.uppercased()]).runOnce()

        #expect(summary == TranscriptRetentionSummary())
        #expect(manager.fileExists(atPath: main.path))
        #expect(manager.fileExists(atPath: subagent.path))
    }

    @Test func codexRolloutsAreArchivedToo() async throws {
        let codex = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        let rollout = try write("2026/09/03/rollout-2026-09-03T15-40-16-01a0677f-ae4e-7fb3-8baf-744b2d3de0e5.jsonl", "{}\n", ageDays: 60, under: codex)

        let summary = await archiver().runOnce()

        #expect(summary.compressed == 1)
        #expect(manager.fileExists(atPath: rollout.path + ".gz"))
    }

    @Test func linksAreNeverFollowed() async throws {
        let outside = home.appendingPathComponent("fuera", isDirectory: true)
        let target = try write("77777777-7777-4777-8777-777777777777.jsonl", "fuera\n", ageDays: 90, under: outside)
        try manager.createDirectory(at: claude, withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: claude.appendingPathComponent("enlace"), withDestinationURL: outside)

        let summary = await archiver().runOnce()

        #expect(summary == TranscriptRetentionSummary())
        #expect(manager.fileExists(atPath: target.path))
    }

    @Test func theUUIDsOfAnyTextAreFoundInLowerCase() {
        let state = #"{"agent":{"sessionId":"A9391254-C89B-4A93-84BD-4EE48FF6EE1F"},"id":"no-uuid"}"#
        #expect(ConversationIDScanner().ids(in: state) == ["a9391254-c89b-4a93-84bd-4ee48ff6ee1f"])
    }

    @Test func onlyLiveClaudeProcessesProtectTheirConversation() throws {
        let sessions = home.appendingPathComponent(".claude/sessions", isDirectory: true)
        try manager.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Data(#"{"pid":100,"sessionId":"88888888-8888-4888-8888-888888888888"}"#.utf8).write(to: sessions.appendingPathComponent("100.json"))
        try Data(#"{"pid":200,"sessionId":"99999999-9999-4999-8999-999999999999"}"#.utf8).write(to: sessions.appendingPathComponent("200.json"))

        let ids = ClaudeLiveSessionReader(directory: sessions, isAlive: { $0 == 100 }).conversationIDs()

        #expect(ids == ["88888888-8888-4888-8888-888888888888"])
    }
}

/// The real compressor, but the AI writes to the transcript while it is being compressed.
private struct AppendingWhileCompressing: TranscriptCompressing {
    let original: URL
    private let real = GzipTranscriptCompressor()

    func append(_ source: URL, to destination: URL) async -> Bool {
        let ok = await real.append(source, to: destination)
        guard let handle = try? FileHandle(forWritingTo: original) else { return false }
        handle.seekToEndOfFile()
        handle.write(Data("la IA volvió a escribir\n".utf8))
        try? handle.close()
        return ok
    }

    func verify(_ archive: URL) async -> Bool { await real.verify(archive) }
}
