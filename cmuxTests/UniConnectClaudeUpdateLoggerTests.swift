import Foundation
import Testing
import UniConnectClaudeUpdate

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("UniConnect Claude update structured log")
struct UniConnectClaudeUpdateLoggerTests {
    @Test("Persists only allow-listed identifiers with restrictive permissions")
    func redactsUntrustedIdentifiers() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-update-log-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("events.jsonl")
        let logger = UniConnectClaudeUpdateLogger(fileURL: file)
        let secret = "sshpass -p super-secret ssh root@example.test"
        await logger.record(ClaudeUpdateLogEntry(
            timestamp: Date(timeIntervalSince1970: 1),
            operationID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            level: .error,
            phase: .preflight,
            hostID: secret,
            targetID: ClaudeUpdateTargetID(rawValue: "not-a-uuid-secret"),
            issue: .inspectionFailed
        ))

        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains(secret))
        #expect(!text.contains("super-secret"))
        #expect(!text.contains("not-a-uuid-secret"))
        #expect(text.contains(#""hostID":null"#))
        #expect(text.contains(#""targetID":null"#))
        let fileMode = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int)
        let directoryMode = try #require(try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int)
        #expect(fileMode == 0o600)
        #expect(directoryMode == 0o700)
    }

    @Test("Retains known local and credential UUID identities")
    func retainsSafeIdentifiers() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-update-log-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("events.jsonl")
        let logger = UniConnectClaudeUpdateLogger(fileURL: file)
        let credentialID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let targetID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        await logger.record(ClaudeUpdateLogEntry(
            timestamp: Date(timeIntervalSince1970: 1),
            operationID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            level: .info,
            phase: .updating,
            hostID: UniConnectClaudeUpdateHostID.remote(credentialID: credentialID),
            targetID: ClaudeUpdateTargetID(rawValue: targetID.uuidString),
            issue: nil
        ))

        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains(UniConnectClaudeUpdateHostID.remote(credentialID: credentialID)))
        #expect(text.lowercased().contains(targetID.uuidString.lowercased()))
    }
}
