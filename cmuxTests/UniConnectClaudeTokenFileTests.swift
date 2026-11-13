import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// A Claude started with `CLAUDE_CODE_OAUTH_TOKEN` (`claude-kin`) resumes on the same token: the
/// window keeps the path of the file that holds it, never the token.
@MainActor
@Suite("Claude token files on resume")
struct UniConnectClaudeTokenFileTests {
    nonisolated private static let token = "sk-ant-oat01-prueba-kin"

    /// A temporary home with the user's token file and decoys that must never be chosen.
    private struct Home {
        let url: URL
        let tokenFile: URL

        init() throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("uc-token-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            tokenFile = url.appendingPathComponent(".claude-kin-token", isDirectory: false)
            try write(".claude-kin-token", UniConnectClaudeTokenFileTests.token + "\n", mode: 0o600)
            // Same token, but anyone in the group could have written it.
            try write(".claude-aaa-token", UniConnectClaudeTokenFileTests.token, mode: 0o620)
            // Same token under a name that is not a token file.
            try write("notas-token.txt", UniConnectClaudeTokenFileTests.token, mode: 0o600)
            // Another account's token.
            try write(".claude-otra-token", "sk-ant-oat01-otra", mode: 0o600)
            try FileManager.default.createSymbolicLink(
                at: url.appendingPathComponent(".claude-enlace-token"), withDestinationURL: tokenFile
            )
        }

        func write(_ name: String, _ content: String, mode: Int) throws {
            let file = url.appendingPathComponent(name, isDirectory: false)
            try Data(content.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        }

        func remove() { try? FileManager.default.removeItem(at: url) }
    }

    @Test("Only the user's private token file holding exactly that token is chosen")
    func findsTheTokenFile() throws {
        let home = try Home()
        defer { home.remove() }
        let files = UniConnectClaudeTokenFile(homeDirectory: home.url, userID: getuid())
        #expect(files.file(holding: Self.token) == home.tokenFile.path)
        #expect(files.observation(environment: ["CLAUDE_CODE_OAUTH_TOKEN": Self.token]) == .file(home.tokenFile.path))
        #expect(files.observation(environment: ["CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-de-nadie"]) == .unmatched)
        #expect(files.observation(environment: ["HOME": home.url.path]) == .noToken)
        #expect(files.observation(environment: ["CLAUDE_CODE_OAUTH_TOKEN": "  "]) == .noToken)
    }

    @Test("A token file of another user is never chosen")
    func ignoresFilesOfAnotherOwner() throws {
        let home = try Home()
        defer { home.remove() }
        let files = UniConnectClaudeTokenFile(homeDirectory: home.url, userID: getuid() &+ 1)
        #expect(files.file(holding: Self.token) == nil)
    }

    @Test("The shell assignment reads the token from the file when the command runs")
    func shellAssignmentReadsTheFile() throws {
        let home = try Home()
        defer { home.remove() }
        // A path with a quote and a space still reaches cat as one argument.
        try home.write("claude kin's token", Self.token, mode: 0o600)
        let path = home.url.appendingPathComponent("claude kin's token").path
        let assignment = try #require(UniConnectClaudeTokenFile.shellAssignment(path: path))
        #expect(!assignment.contains(Self.token))
        let printed = try Self.runShell("\(assignment) /bin/sh -c 'printf %s \"$CLAUDE_CODE_OAUTH_TOKEN\"'")
        #expect(printed == Self.token)
        #expect(UniConnectClaudeTokenFile.shellAssignment(path: "relativo/.claude-kin-token") == nil)
        #expect(UniConnectClaudeTokenFile.shellAssignment(path: "/tmp/a\nb") == nil)
    }

    @Test("Resuming a Claude saved with its token file starts it with that token and nothing else changes")
    func resumeCommandCarriesTheToken() throws {
        let home = try Home()
        defer { home.remove() }
        let sessionID = UUID().uuidString.lowercased()
        let conversation = try #require(UniConnectLocalAgentConversation(
            kind: .claude, sessionID: sessionID, resumeWorkingDirectory: home.url.path,
            claudeTokenFile: home.tokenFile.path
        ))
        let snapshot = conversation.restorableSnapshot(
            workingDirectory: home.url.path, registry: CmuxVaultAgentRegistry(registrations: [])
        )
        let command = try #require(snapshot.resumeCommand)
        #expect(!command.contains(Self.token))

        // A fake `claude` prints the token it received and its arguments.
        let bin = home.url.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fake = bin.appendingPathComponent("claude")
        try Data("#!/bin/sh\nprintf '%s|%s' \"$CLAUDE_CODE_OAUTH_TOKEN\" \"$*\"\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let printed = try Self.runShell(command, path: bin.path + ":/usr/bin:/bin")
        let parts = printed.split(separator: "|", maxSplits: 1).map(String.init)
        #expect(parts.first == Self.token)
        #expect(parts.last?.contains("--resume \(sessionID)") == true)

        // The same conversation without a token file resumes on the usual login.
        let plain = try #require(UniConnectLocalAgentConversation(kind: .claude, sessionID: sessionID))
        let plainCommand = try #require(plain.restorableSnapshot(
            workingDirectory: home.url.path, registry: CmuxVaultAgentRegistry(registrations: [])
        ).resumeCommand)
        #expect(!plainCommand.contains("CLAUDE_CODE_OAUTH_TOKEN"))
        let plainPrinted = try Self.runShell(plainCommand, path: bin.path + ":/usr/bin:/bin")
        #expect(plainPrinted.hasPrefix("|"))
    }

    @Test("The token file survives a save and an old save without it still loads")
    func conversationCodable() throws {
        let sessionID = UUID().uuidString
        let conversation = try #require(UniConnectLocalAgentConversation(
            kind: .claude, sessionID: sessionID, claudeTokenFile: "/Users/dani/.claude-kin-token"
        ))
        let data = try JSONEncoder().encode(conversation)
        let decoded = try JSONDecoder().decode(UniConnectLocalAgentConversation.self, from: data)
        #expect(decoded.claudeTokenFile == "/Users/dani/.claude-kin-token")
        #expect(decoded == conversation)

        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "claudeTokenFile")
        let old = try JSONDecoder().decode(
            UniConnectLocalAgentConversation.self, from: try JSONSerialization.data(withJSONObject: object)
        )
        #expect(old.claudeTokenFile == nil)
        #expect(old.sessionID == sessionID)

        // Only Claude reads a token file; a relative path is never kept.
        #expect(UniConnectLocalAgentConversation(
            kind: .codex, sessionID: sessionID, claudeTokenFile: "/Users/dani/.claude-kin-token"
        )?.claudeTokenFile == nil)
        #expect(UniConnectLocalAgentConversation(
            kind: .claude, sessionID: sessionID, claudeTokenFile: "relativo"
        )?.claudeTokenFile == nil)
    }

    @Test("The window follows what the live Claude says about its token, and keeps it when it says nothing")
    func windowRecordFollowsTheLiveToken() throws {
        let sessionID = UUID().uuidString
        let observed = AgentObservedConversation(
            provider: .claude, sessionID: sessionID, workingDirectory: "/tmp",
            asRoot: false, source: .argv, processID: 234
        )
        var record = UniConnectLocalWindowRecord(id: UUID(), boxRoot: "/tmp")

        // First seen without reading its environment: nothing is known about a token.
        let unknown = try #require(UniConnectCoordinator.localAgentSnapshot(for: observed))
        let firstSeen = record.record(unknown)
        #expect(firstSeen)
        #expect(record.activeConversation?.claudeTokenFile == nil)

        // Restarted with `claude-kin`: same conversation, now with the token file.
        let withToken = try #require(UniConnectCoordinator.localAgentSnapshot(
            for: observed, claudeToken: .file("/Users/dani/.claude-kin-token")
        ))
        let active = try #require(record.activeConversation)
        #expect(!UniConnectCoordinator.claudeTokenIsRecorded(.file("/Users/dani/.claude-kin-token"), in: active))
        let tokenRecorded = record.record(withToken)
        #expect(tokenRecorded)
        let updated = try #require(record.activeConversation)
        #expect(updated.claudeTokenFile == "/Users/dani/.claude-kin-token")
        #expect(updated.id == active.id)
        #expect(record.conversations.count == 1)
        #expect(UniConnectCoordinator.claudeTokenIsRecorded(.file("/Users/dani/.claude-kin-token"), in: updated))

        // A token no file holds, or an unreadable environment, changes nothing.
        #expect(UniConnectCoordinator.claudeTokenIsRecorded(.unmatched, in: updated))
        #expect(UniConnectCoordinator.claudeTokenIsRecorded(nil, in: updated))
        let unmatched = try #require(UniConnectCoordinator.localAgentSnapshot(for: observed, claudeToken: .unmatched))
        let unmatchedChanged = record.record(unmatched)
        #expect(!unmatchedChanged)
        #expect(record.activeConversation?.claudeTokenFile == "/Users/dani/.claude-kin-token")

        // Restarted with plain `claude`: back to the usual login.
        let plain = try #require(UniConnectCoordinator.localAgentSnapshot(for: observed, claudeToken: .noToken))
        let plainChanged = record.record(plain)
        #expect(plainChanged)
        #expect(record.activeConversation?.claudeTokenFile == nil)
    }

    private static func runShell(_ command: String, path: String = "/usr/bin:/bin") throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["PATH": path, "HOME": NSHomeDirectory()]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
