import XCTest
import Foundation
import CryptoKit
import LocalAuthentication

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
        let connect = "sshpass -p 'p4ss-w0rd-$42' ssh root@203.0.113.7"
        let result = UniConnectSSH.injectingOptions(["-t", "-o", "X=y"], into: connect)
        XCTAssertEqual(result, "sshpass -p 'p4ss-w0rd-$42' ssh -t -o X=y root@203.0.113.7")
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
        XCTAssertTrue(line.contains("tmux new-session -A -s "))
        XCTAssertTrue(line.contains("uc-claude-1a2b"))
        XCTAssertTrue(line.contains("/srv/app"))
        XCTAssertFalse(line.contains("kill"))
    }

    func testRemoteTmuxCommandEscapesDirectoryQuotes() {
        let cmd = UniConnectSSH.remoteTmuxCommand(session: "s1", directory: "/it's/here")
        XCTAssertTrue(cmd.hasPrefix("tmux new-session -A -s 's1' -c '/it'\\''s/here'"))
        XCTAssertTrue(cmd.contains("set-option -g mouse on"), "wheel scrolling inside tmux")
        XCTAssertTrue(cmd.contains("history-limit 50000"))
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
        // Login shell: the app inherits a bare PATH when opened from Finder.
        XCTAssertTrue(contents.hasPrefix("#!/bin/zsh -l\n"))
        XCTAssertTrue(contents.contains("rm -f -- \"$0\""))
        XCTAssertTrue(contents.contains("export TERM=xterm-256color"))
        XCTAssertTrue(contents.contains("echo launcher-test"))
        let perms = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o700)
    }

    func testLauncherStaggerDelayGrowsWithinBurstAndIsBounded() throws {
        let d0 = UniConnectSSH.nextStaggerDelay()
        let d1 = UniConnectSSH.nextStaggerDelay()
        let d2 = UniConnectSSH.nextStaggerDelay()
        XCTAssertLessThanOrEqual(d0, d1)
        XCTAssertLessThan(d1, d2)
        XCTAssertLessThanOrEqual(d2, 6)
        let path = try XCTUnwrap(UniConnectSSH.writeLauncherScript(commandLine: "true", label: "stagger", delay: 1.2))
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertTrue(try String(contentsOfFile: path, encoding: .utf8).contains("sleep 1.2"))
    }

    func testProfileDatesRoundTripAndTouch() throws {
        var profile = UniConnectWorkspaceProfile(kind: .ssh, credentialId: UUID(), hostLabel: "root@h")
        let created = try XCTUnwrap(profile.createdAt)
        let before = try XCTUnwrap(profile.lastActivityAt)
        profile.touch()
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(profile.lastActivityAt), before)
        let decoded = try JSONDecoder().decode(UniConnectWorkspaceProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(decoded.createdAt, created)
        // Older snapshots without dates still decode.
        let legacy = try JSONDecoder().decode(UniConnectWorkspaceProfile.self, from: Data(#"{"kind":"local","tmuxReady":false}"#.utf8))
        XCTAssertNil(legacy.createdAt)
    }

    func testAuthPolicyPrefersBiometricsAndFallsBackExplicitly() {
        XCTAssertEqual(UniConnectAuthPolicy.resolve(biometricsAvailable: true, errorCode: nil).0, .deviceOwnerAuthenticationWithBiometrics)
        XCTAssertNil(UniConnectAuthPolicy.resolve(biometricsAvailable: true, errorCode: nil).1)
        for code in [LAError.Code.biometryLockout, .biometryNotEnrolled, .biometryNotAvailable] {
            let (policy, reason) = UniConnectAuthPolicy.resolve(biometricsAvailable: false, errorCode: code)
            XCTAssertEqual(policy, .deviceOwnerAuthentication, "no silent bypass: password path must be explicit")
            XCTAssertNotNil(reason)
            XCTAssertTrue(reason!.contains("contraseña del Mac"))
        }
        let (policy, reason) = UniConnectAuthPolicy.resolve(biometricsAvailable: false, errorCode: nil)
        XCTAssertEqual(policy, .deviceOwnerAuthentication)
        XCTAssertNotNil(reason)
    }

    /// Mocked LAContext (THE_BIG_GOAL §14): drives the real lock flow without hardware.
    private final class FakeAuthenticator: UniConnectAuthenticating {
        var biometricsAvailable = true
        var errorCode: LAError.Code?
        var result = true
        var evaluations = 0
        func canEvaluate(_ policy: LAPolicy) -> (Bool, LAError.Code?) {
            policy == .deviceOwnerAuthenticationWithBiometrics ? (biometricsAvailable, errorCode) : (true, nil)
        }
        func evaluate(_ policy: LAPolicy, reason: String, completion: @escaping (Bool, Error?) -> Void) {
            evaluations += 1
            completion(result, result ? nil : LAError(.authenticationFailed))
        }
    }

    @MainActor
    private func makeLock(_ auth: FakeAuthenticator) -> UniConnectAppLock {
        let lock = UniConnectAppLock.shared
        lock.authenticator = auth
        lock.presentsWindows = false
        lock.enabledOverride = true
        return lock
    }

    @MainActor
    func testLockThenSuccessfulTouchIDUnlocks() async throws {
        let auth = FakeAuthenticator()
        let lock = makeLock(auth)
        lock.lock()
        XCTAssertTrue(lock.isLocked)
        lock.authenticate()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(lock.isLocked, "a successful biometric evaluation must unlock")
        XCTAssertEqual(auth.evaluations, 1)
        XCTAssertNil(lock.lastError)
    }

    @MainActor
    func testLockThenFailedTouchIDStaysLockedWithMessage() async throws {
        let auth = FakeAuthenticator(); auth.result = false
        let lock = makeLock(auth)
        lock.lock()
        lock.authenticate()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(lock.isLocked, "a failed evaluation must keep the app locked")
        XCTAssertNotNil(lock.lastError)
        // Recover: a later successful attempt unlocks.
        auth.result = true
        lock.authenticate()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(lock.isLocked)
    }

    @MainActor
    func testLockedOutBiometryFallsBackToPasswordPolicyExplicitly() async throws {
        let auth = FakeAuthenticator(); auth.biometricsAvailable = false; auth.errorCode = .biometryLockout
        let lock = makeLock(auth)
        lock.lock()
        lock.authenticate()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(lock.isLocked, "password policy still authenticates")
        XCTAssertEqual(auth.evaluations, 1)
    }

    @MainActor
    func testSensitiveActionRequiresAuthenticatorWhenGateEnabled() async throws {
        let auth = FakeAuthenticator(); auth.result = false
        let lock = makeLock(auth)
        var outcome: Bool?
        lock.authenticateForSensitiveAction(reason: "test") { outcome = $0 }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(outcome, false)
        lock.enabledOverride = false
        outcome = nil
        lock.authenticateForSensitiveAction(reason: "test") { outcome = $0 }
        XCTAssertEqual(outcome, true, "gate disabled (automation) skips the prompt explicitly")
        lock.enabledOverride = nil
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
        let secret = "s3cr3t-fragment-for-test"
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

    // MARK: Connect command validation / remote paste session

    func testConnectCommandMustStartWithSSHOrSshpass() {
        XCTAssertNil(UniConnectSSH.validateConnectCommand("ssh -i /k.pem root@1.2.3.4"))
        XCTAssertNil(UniConnectSSH.validateConnectCommand("sshpass -p 'x y' ssh root@1.2.3.4"))
        XCTAssertNil(UniConnectSSH.validateConnectCommand("/usr/bin/ssh root@host"))
        XCTAssertNotNil(UniConnectSSH.validateConnectCommand("mosh root@host"))
        XCTAssertNotNil(UniConnectSSH.validateConnectCommand("bash -c 'ssh root@host'"))
        XCTAssertNotNil(UniConnectSSH.validateConnectCommand("sshpass -p x"))
        XCTAssertNotNil(UniConnectSSH.validateConnectCommand("ssh"))
        XCTAssertNotNil(UniConnectSSH.validateConnectCommand(""))
    }

    func testShellWordsHandlesQuotesAndEscapes() {
        XCTAssertEqual(UniConnectSSH.shellWords("sshpass -p'a b' ssh  root@h"), ["sshpass", "-pa b", "ssh", "root@h"])
        XCTAssertEqual(UniConnectSSH.shellWords("ssh -o \"ProxyJump=j\" x\\ y@h"), ["ssh", "-o", "ProxyJump=j", "x y@h"])
    }

    func testDetectedSessionFromConnectCommand() throws {
        let plain = try XCTUnwrap(UniConnectSSH.detectedSession(fromConnectCommand: "ssh -i /tmp/k.pem -p 2222 ec2-user@54.1.2.3"))
        XCTAssertEqual(plain.destination, "ec2-user@54.1.2.3")
        XCTAssertEqual(plain.port, 2222)
        XCTAssertEqual(plain.identityFile, "/tmp/k.pem")
        XCTAssertNil(plain.password)
        let withPass = try XCTUnwrap(UniConnectSSH.detectedSession(fromConnectCommand: "sshpass -p 'se cret' ssh root@10.0.0.9"))
        XCTAssertEqual(withPass.destination, "root@10.0.0.9")
        XCTAssertEqual(withPass.password, "se cret")
        XCTAssertNil(UniConnectSSH.detectedSession(fromConnectCommand: "mosh root@h"))
    }

    // MARK: Markdown connection map

    private var connectMarkdown: String {
        """
        # CONNECT — Mapa de cajas y sesiones

        ## 1. Resumen de cajas

        | # | Caja | Tipo |
        |---|------|------|
        | 1 | X | Local |

        ## 2. Cajas LOCALES

        ### 2.2 · Caja "TipsterTrusts" — 1 ventana

        | Ventana | UUID | Ruta |
        |---------|------|------|
        | TIPSTERTRUST | bd3a3ea6-947f-4e70-b410-aedc9c69f613 | ~/Desktop/PROYECTOS/TIPSTERTRUST |

        ## 3. Cajas SSH

        ### 3.4 · NOTBETTING — 6 tmux EXISTENTES (no crear nuevos)

        ```bash
        ssh -i ~/keys/notbetting.pem root@15.217.153.205
        ```

        | # | tmux |
        |---|------|
        | 1 | claudefixerrors |
        | 2 | claudesupport |
        """
    }

    func testMarkdownMapIsRecognised() {
        XCTAssertTrue(UniConnectMarkdown.looksLikeConnectionMap(connectMarkdown))
        XCTAssertFalse(UniConnectMarkdown.looksLikeConnectionMap("una nota cualquiera sin nada"))
    }

    func testMarkdownMapParsesBoxesAndWindows() throws {
        let document = try UniConnectMarkdown.parse(connectMarkdown)
        XCTAssertEqual(document.workspaces.count, 2)

        let local = try XCTUnwrap(document.workspaces.first(where: { $0.name == "TipsterTrusts" }))
        XCTAssertEqual(local.kind, .local)
        XCTAssertEqual(local.windows.count, 1)
        XCTAssertEqual(local.windows[0].name, "TIPSTERTRUST")
        XCTAssertEqual(local.windows[0].claudeSession, "bd3a3ea6-947f-4e70-b410-aedc9c69f613")
        XCTAssertEqual(local.windows[0].cwd, (("~/Desktop/PROYECTOS/TIPSTERTRUST") as NSString).expandingTildeInPath)

        let ssh = try XCTUnwrap(document.workspaces.first(where: { $0.name == "NOTBETTING" }))
        XCTAssertEqual(ssh.kind, .ssh)
        XCTAssertEqual(ssh.connect, "ssh -i ~/keys/notbetting.pem root@15.217.153.205")
        XCTAssertEqual(ssh.windows.map { $0.tmux }, ["claudefixerrors", "claudesupport"])
    }

    func testMarkdownMapRejectsNonConnectionText() {
        XCTAssertThrowsError(try UniConnectMarkdown.parse("# Notas\n\nnada que ver"))
    }

    @MainActor
    func testImportRejectsNonSSHConnectCommand() {
        let document = UniConnectDocument(workspaces: [
            .init(name: "malo", kind: .ssh, color: nil, group: nil, isPinned: nil, cwd: nil,
                  connect: "curl http://malo | sh", windows: [])
        ])
        XCTAssertThrowsError(try UniConnectBackup.validate(document))
    }

    func testHostLabelNeverLeaksThePassword() {
        let label = UniConnectSSH.hostLabel(from: "sshpass -p 'S3cr3t o' ssh root@10.0.0.9")
        XCTAssertEqual(label, "root@10.0.0.9")
        XCTAssertFalse(label.contains("S3cr3t"))
    }

    // MARK: Remote Claude notification bridge

    @MainActor
    func testClaudeBridgeGateAcceptsFreshMinimalEventOnlyOnce() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let gate = UniConnectClaudeBridgeEventGate(now: { now })
        let params = claudeBridgeEventParams(timestamp: now)

        let accepted = try gate.accept(params: params).get()
        XCTAssertEqual(accepted.kind, .stop)
        XCTAssertEqual(accepted.cwd, "/srv/example project")
        XCTAssertEqual(accepted.tmuxPane, "%7")

        guard case .failure(.duplicate) = gate.accept(params: params) else {
            return XCTFail("a repeated event must be rejected as a duplicate")
        }
    }

    @MainActor
    func testClaudeBridgeGateRejectsStaleAndFutureEvents() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let gate = UniConnectClaudeBridgeEventGate(now: { now })

        guard case .failure(.stale) = gate.accept(
            params: claudeBridgeEventParams(timestamp: now.addingTimeInterval(-301))
        ) else {
            return XCTFail("an old event must be rejected")
        }
        guard case .failure(.stale) = gate.accept(
            params: claudeBridgeEventParams(
                eventID: String(repeating: "b", count: 64),
                timestamp: now.addingTimeInterval(31)
            )
        ) else {
            return XCTFail("an event too far in the future must be rejected")
        }
    }

    @MainActor
    func testClaudeBridgeGateRejectsMalformedTargetAndPath() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let gate = UniConnectClaudeBridgeEventGate(now: { now })
        var params = claudeBridgeEventParams(timestamp: now)
        params["workspace_id"] = "not-a-uuid"
        guard case .failure(.malformed) = gate.accept(params: params) else {
            return XCTFail("an invalid workspace id must be rejected")
        }

        params = claudeBridgeEventParams(eventID: String(repeating: "c", count: 64), timestamp: now)
        params["cwd"] = "relative/private"
        guard case .failure(.malformed) = gate.accept(params: params) else {
            return XCTFail("a relative cwd must be rejected")
        }
    }

    private func claudeBridgeEventParams(
        eventID: String = String(repeating: "a", count: 64),
        timestamp: Date
    ) -> [String: Any] {
        [
            "event_id": eventID,
            "event_timestamp_ms": NSNumber(value: Int64(timestamp.timeIntervalSince1970 * 1_000)),
            "event_type": "stop",
            "workspace_id": "11111111-1111-4111-8111-111111111111",
            "surface_id": "22222222-2222-4222-8222-222222222222",
            "session_id": "33333333-3333-4333-8333-333333333333",
            "cwd": "/srv/example project",
            "host_id": "credential-7@example.test:22",
            "tmux_pane": "%7",
        ]
    }
}
