import XCTest
import Foundation
import CryptoKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class UniConnectTests: XCTestCase {

    // MARK: - tmux IDs

    func testSanitizedTmuxNameKeepsSafeCharacters() {
        XCTAssertEqual(UniConnectSSH.sanitizedTmuxName("uc-claude-1a2b"), "uc-claude-1a2b")
        XCTAssertEqual(UniConnectSSH.sanitizedTmuxName("logs_prod"), "logs_prod")
    }

    func testSanitizedTmuxNameStripsInjectionAttempts() {
        let hostile = "x'; rm -rf / #; $(reboot) `id` \n|&"
        let safe = UniConnectSSH.sanitizedTmuxName(hostile)
        XCTAssertFalse(safe.contains("'"))
        XCTAssertFalse(safe.contains(";"))
        XCTAssertFalse(safe.contains("$"))
        XCTAssertFalse(safe.contains("`"))
        XCTAssertFalse(safe.contains("\n"))
        XCTAssertFalse(safe.contains("|"))
        XCTAssertFalse(safe.contains("&"))
        XCTAssertFalse(safe.contains(" "))
        XCTAssertTrue(safe.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    func testSanitizedTmuxNameRejectsDotsAndColons() {
        // tmux itself forbids '.' and ':' in session names.
        XCTAssertEqual(UniConnectSSH.sanitizedTmuxName("a.b:c"), "a-b-c")
    }

    func testSanitizedTmuxNameHasLengthLimitAndFallback() {
        XCTAssertLessThanOrEqual(UniConnectSSH.sanitizedTmuxName(String(repeating: "a", count: 200)).count, 40)
        XCTAssertEqual(UniConnectSSH.sanitizedTmuxName("!!!"), "ventana")
    }

    func testSuggestedTmuxNamesAreUnique() {
        let a = UniConnectSSH.suggestedTmuxName(windowName: "claude")
        let b = UniConnectSSH.suggestedTmuxName(windowName: "claude")
        XCTAssertTrue(a.hasPrefix("uc-claude-"))
        XCTAssertNotEqual(a, b)
    }

    // MARK: - SSH command construction

    func testInjectsOptionsAfterSshInsideSshpassWrapper() {
        let connect = "sshpass -p 'boirow23-$2237' ssh root@185.237.234.47"
        let result = UniConnectSSH.injectingOptions(["-t", "-o", "X=y"], into: connect)
        XCTAssertEqual(result, "sshpass -p 'boirow23-$2237' ssh -t -o X=y root@185.237.234.47")
    }

    func testInjectsOptionsAfterPlainSshWithIdentity() {
        let connect = "ssh -i /path/key.pem root@1.2.3.4"
        let result = UniConnectSSH.injectingOptions(["-t"], into: connect)
        XCTAssertEqual(result, "ssh -t -i /path/key.pem root@1.2.3.4")
    }

    func testInjectsOptionsAppendsWhenNoSshWord() {
        XCTAssertEqual(UniConnectSSH.injectingOptions(["-t"], into: "my-wrapper host"), "my-wrapper host -t")
    }

    func testAttachCommandLineQuotesRemoteCommandAndUsesSafeSession() {
        let line = UniConnectSSH.attachCommandLine(
            connectCommand: "ssh root@1.2.3.4",
            session: "uc-claude-1a2b",
            directory: "/srv/app"
        )
        XCTAssertTrue(line.hasPrefix("ssh -t -o StrictHostKeyChecking=accept-new"))
        // The remote command is single-quoted for the local shell, so inner quotes are
        // escaped as '\'' — check the unescaped pieces instead of the literal string.
        XCTAssertTrue(line.contains("tmux new-session -A -D -s "))
        XCTAssertTrue(line.contains("uc-claude-1a2b"))
        XCTAssertTrue(line.contains("/srv/app"))
        XCTAssertFalse(line.contains("kill"))
    }

    func testRemoteTmuxCommandEscapesDirectoryQuotes() {
        let cmd = UniConnectSSH.remoteTmuxCommand(session: "s1", directory: "/it's/here")
        XCTAssertEqual(cmd, "tmux new-session -A -D -s 's1' -c '/it'\\''s/here'")
    }

    func testHostLabelNeverContainsPassword() {
        let label = UniConnectSSH.hostLabel(from: "sshpass -p 'SuperSecret' ssh root@10.0.0.9")
        XCTAssertEqual(label, "root@10.0.0.9")
        XCTAssertFalse(label.contains("SuperSecret"))
    }

    func testLauncherScriptPinsTermAndSelfDeletes() throws {
        let path = try XCTUnwrap(UniConnectSSH.writeLauncherScript(commandLine: "echo launcher-test", label: "unit test"))
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertFalse(path.contains(" "), "Ghostty splits the command on whitespace")
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(contents.hasPrefix("#!/bin/zsh\n"))
        XCTAssertTrue(contents.contains("rm -f -- \"$0\""))
        XCTAssertTrue(contents.contains("export TERM=xterm-256color"))
        XCTAssertTrue(contents.contains("echo launcher-test"))
        let perms = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o700)
    }

    func testTmuxProbeScriptNeverKillsSessions() {
        XCTAssertFalse(UniConnectTmuxProbe.remoteScript.contains("kill-session"))
        XCTAssertFalse(UniConnectTmuxProbe.remoteScript.contains("kill-server"))
        XCTAssertTrue(UniConnectTmuxProbe.remoteScript.contains("command -v tmux"))
    }

    // MARK: - Crypto

    func testSealOpenRoundTripWithMasterKey() throws {
        let key = SymmetricKey(size: .bits256)
        let plaintext = Data("hola caracola".utf8)
        let sealed = try UniConnectCrypto.seal(plaintext, key: key)
        let envelope = try UniConnectCrypto.parseEnvelope(sealed)
        XCTAssertEqual(envelope.format, UniConnectCrypto.formatName)
        XCTAssertNil(envelope.kdf)
        XCTAssertEqual(try UniConnectCrypto.open(envelope, key: key), plaintext)
    }

    func testPassphraseRoundTripAndWrongPassphrase() throws {
        let plaintext = Data("{\"connect\":\"sshpass -p x ssh root@h\"}".utf8)
        let sealed = try UniConnectCrypto.sealWithPassphrase(plaintext, passphrase: "correct horse")
        XCTAssertEqual(try UniConnectCrypto.openWithPassphrase(sealed, passphrase: "correct horse"), plaintext)
        XCTAssertThrowsError(try UniConnectCrypto.openWithPassphrase(sealed, passphrase: "wrong")) { error in
            guard case UniConnectError.badPassphrase = error else { return XCTFail("expected badPassphrase, got \(error)") }
        }
    }

    func testCiphertextDoesNotLeakPlaintext() throws {
        let secret = "boirow23-sglkb233-lkg82"
        let sealed = try UniConnectCrypto.sealWithPassphrase(Data(secret.utf8), passphrase: "pw-123456")
        XCTAssertFalse(String(decoding: sealed, as: UTF8.self).contains(secret))
    }

    func testTamperedCiphertextIsRejected() throws {
        let sealed = try UniConnectCrypto.sealWithPassphrase(Data("payload".utf8), passphrase: "pw-123456")
        var envelope = try UniConnectCrypto.parseEnvelope(sealed)
        var bytes = [UInt8](Data(base64Encoded: envelope.ciphertext)!)
        bytes[0] ^= 0xFF
        envelope.ciphertext = Data(bytes).base64EncodedString()
        let salt = Data(base64Encoded: envelope.salt!)!
        let key = UniConnectCrypto.passphraseKey("pw-123456", salt: salt, iterations: envelope.iterations!)
        XCTAssertThrowsError(try UniConnectCrypto.open(envelope, key: key))
    }

    func testTamperedTagIsRejected() throws {
        let key = SymmetricKey(size: .bits256)
        let sealed = try UniConnectCrypto.seal(Data("payload".utf8), key: key)
        var envelope = try UniConnectCrypto.parseEnvelope(sealed)
        var tag = [UInt8](Data(base64Encoded: envelope.tag)!)
        tag[3] ^= 0x01
        envelope.tag = Data(tag).base64EncodedString()
        XCTAssertThrowsError(try UniConnectCrypto.open(envelope, key: key))
    }

    func testTruncatedFileIsRejected() throws {
        let sealed = try UniConnectCrypto.sealWithPassphrase(Data("payload".utf8), passphrase: "pw-123456")
        let truncated = sealed.prefix(sealed.count / 2)
        XCTAssertThrowsError(try UniConnectCrypto.parseEnvelope(truncated))
    }

    func testSaltsAndNoncesAreUniquePerSeal() throws {
        var salts = Set<String>()
        var nonces = Set<String>()
        for _ in 0..<5 {
            let sealed = try UniConnectCrypto.seal(Data("x".utf8), key: SymmetricKey(size: .bits256), kdf: (UniConnectCrypto.randomSalt(), 1000))
            let envelope = try UniConnectCrypto.parseEnvelope(sealed)
            salts.insert(envelope.salt!)
            nonces.insert(envelope.nonce)
        }
        XCTAssertEqual(salts.count, 5)
        XCTAssertEqual(nonces.count, 5)
    }

    // MARK: - Export container / document

    @MainActor
    func testExportContainerHasReadableMetaAndEncryptedPayload() throws {
        let document = UniConnectDocument(workspaces: [
            .init(name: "VPS", kind: .ssh, color: "#C0392B", group: nil, isPinned: nil, cwd: nil,
                  connect: "sshpass -p 'S3cret' ssh root@9.9.9.9",
                  windows: [.init(name: "claude", tmux: "uc-claude", claudeSession: nil, cwd: nil, isPinned: nil)])
        ])
        let data = try UniConnectBackup.exportData(document: document, passphrase: "pw-123456")
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"format\" : \"uniconnect-export\""))
        XCTAssertFalse(text.contains("S3cret"))
        XCTAssertFalse(text.contains("9.9.9.9"))
        guard case .encrypted(let container) = try UniConnectBackup.inspect(data: data) else { return XCTFail("expected container") }
        XCTAssertEqual(container.meta.workspaces, 1)
        let restored = try UniConnectBackup.decrypt(container: container, passphrase: "pw-123456")
        XCTAssertEqual(restored, document)
        XCTAssertThrowsError(try UniConnectBackup.decrypt(container: container, passphrase: "nope"))
    }

    @MainActor
    func testInspectAcceptsPlainSeedAndRejectsGarbage() throws {
        let seed = UniConnectBackup.seedTemplate()
        guard case .plainSeed(let doc) = try UniConnectBackup.inspect(data: Data(seed.utf8)) else { return XCTFail("seed") }
        XCTAssertEqual(doc.workspaces.count, 2)
        XCTAssertThrowsError(try UniConnectBackup.inspect(data: Data("{\"nope\":1}".utf8)))
        XCTAssertThrowsError(try UniConnectBackup.inspect(data: Data("not json".utf8)))
    }

    @MainActor
    func testValidateRejectsBadDocuments() {
        var doc = UniConnectDocument(workspaces: [
            .init(name: "SSH sin conexión", kind: .ssh, color: nil, group: nil, isPinned: nil, cwd: nil, connect: nil, windows: [])
        ])
        XCTAssertThrowsError(try UniConnectBackup.validate(doc))
        doc = UniConnectDocument(workspaces: [
            .init(name: "SSH", kind: .ssh, color: nil, group: nil, isPinned: nil, cwd: nil, connect: "ssh a@b",
                  windows: [.init(name: "w", tmux: "bad;id", claudeSession: nil, cwd: nil, isPinned: nil)])
        ])
        XCTAssertThrowsError(try UniConnectBackup.validate(doc))
        doc.version = 99
        XCTAssertThrowsError(try UniConnectBackup.validate(doc))
    }

    // MARK: - Session snapshot fields

    func testWorkspaceProfileRoundTripsInsideSessionSnapshot() throws {
        let profile = UniConnectWorkspaceProfile(kind: .ssh, credentialId: UUID(), hostLabel: "root@h", tmuxReady: true)
        let terminal = SessionTerminalPanelSnapshot(workingDirectory: "/x", uniConnectTmuxSession: "uc-a-1")
        let panel = SessionPanelSnapshot(
            id: UUID(), type: .terminal, title: "t", customTitle: nil, directory: nil, isPinned: false,
            isManuallyUnread: false, gitBranch: nil, listeningPorts: [], ttyName: nil,
            terminal: terminal, browser: nil, markdown: nil, filePreview: nil, rightSidebarTool: nil, project: nil
        )
        let workspace = SessionWorkspaceSnapshot(
            workspaceId: UUID(), processTitle: "p", customTitle: "VPS", customDescription: nil, customColor: "#123456",
            isPinned: false, currentDirectory: "/", focusedPanelId: nil,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [panel.id], selectedPanelId: panel.id)),
            panels: [panel], statusEntries: [], logEntries: [], progress: nil, gitBranch: nil, remote: nil,
            uniConnect: profile
        )
        let data = try JSONEncoder().encode(workspace)
        let decoded = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: data)
        XCTAssertEqual(decoded.uniConnect, profile)
        XCTAssertEqual(decoded.panels.first?.terminal?.uniConnectTmuxSession, "uc-a-1")
        // No secret material is ever part of the snapshot.
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("sshpass"))
    }

    func testLegacySnapshotWithoutUniConnectFieldsStillDecodes() throws {
        // Build a real pre-UniConnect snapshot by encoding one and stripping the new keys.
        let workspace = SessionWorkspaceSnapshot(
            workspaceId: UUID(), processTitle: "p", customTitle: nil, customDescription: nil, customColor: nil,
            isPinned: false, currentDirectory: "/", focusedPanelId: nil,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
            panels: [], statusEntries: [], logEntries: [], progress: nil, gitBranch: nil, remote: nil,
            uniConnect: UniConnectWorkspaceProfile(kind: .ssh)
        )
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace)) as? [String: Any])
        object.removeValue(forKey: "uniConnect")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: legacy)
        XCTAssertNil(decoded.uniConnect)
        XCTAssertEqual(decoded.processTitle, "p")
    }
}
