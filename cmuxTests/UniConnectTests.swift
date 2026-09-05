import XCTest
import Testing
import Combine
import Foundation
import AppKit
import CryptoKit
import LocalAuthentication
import UniConnectClaudeBridge

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class UniConnectTests: XCTestCase {

    private final class LockMenuActionProbe: NSObject {
        private(set) var invocationCount = 0

        @objc func invoke(_ sender: Any?) {
            invocationCount += 1
        }
    }

    private final class LockNotificationProbe: @unchecked Sendable {
        var count = 0
    }

    private final class LockWindowDismissalProbe: NSPanel {
        private(set) var orderOutCount = 0

        override func orderOut(_ sender: Any?) {
            orderOutCount += 1
            super.orderOut(sender)
        }
    }

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
        XCTAssertEqual(UniConnectSSH.sanitizedTmuxName("!!!"), "window")
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
        guard UniConnectSSHConnectCommandValidator.trustedSSHpassExecutable() != nil else { return }
        let result = UniConnectSSH.injectingOptions(["-t", "-o", "ConnectTimeout=15"], into: connect)
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.contains("SSHPASS='p4ss-w0rd-$42'") == true)
        XCTAssertTrue(result?.contains("'-e' '/usr/bin/ssh'") == true)
        XCTAssertFalse(result?.contains("'-p'") == true)
    }

    func testInjectsOptionsAfterPlainSshWithIdentity() {
        let connect = "ssh -i /path/key.pem root@1.2.3.4"
        let result = UniConnectSSH.injectingOptions(["-t"], into: connect)
        XCTAssertEqual(result, "'/usr/bin/ssh' '-i' '/path/key.pem' '-t' 'root@1.2.3.4'")
    }

    func testInjectsOptionsRejectsUnknownWrappers() {
        XCTAssertNil(UniConnectSSH.injectingOptions(["-t"], into: "my-wrapper host"))
    }

    func testAttachCommandLineQuotesRemoteCommandAndUsesSafeSession() {
        let line = UniConnectSSH.attachCommandLine(
            connectCommand: "ssh root@1.2.3.4",
            session: "uc-claude-1a2b",
            directory: "/srv/app"
        )
        XCTAssertTrue(line?.hasPrefix("'/usr/bin/ssh' ") == true)
        // The remote command is single-quoted for the local shell, so inner quotes are
        // escaped as '\'' — check the unescaped pieces instead of the literal string.
        XCTAssertTrue(line?.contains("tmux set-option -g history-limit 50000 \\; new-session -A -s ") == true)
        XCTAssertTrue(line?.contains("uc-claude-1a2b") == true)
        XCTAssertTrue(line?.contains("/srv/app") == true)
        XCTAssertFalse(line?.contains("kill") == true)
    }

    func testAttachCommandLineKeepsPrivateUnixBridgeAndMultilinePayloadInOneArgument() {
        let remoteSocket = "/tmp/ucb-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-123456781234423492341234567890ab.sock"
        let bridge = ClaudeBridgeConnectionPlan(
            routeID: UUID(),
            sshOptions: [
                "-o", "ExitOnForwardFailure=no",
                "-o", "ClearAllForwardings=no",
                "-o", "StreamLocalBindMask=0177",
                "-o", "StreamLocalBindUnlink=yes",
                "-R", "\(remoteSocket):127.0.0.1:46000",
            ],
            remoteSetupCommand: "printf '%s' 'line one\nline two' >/dev/null",
            remoteCleanupCommand: "true"
        )
        let line = UniConnectSSH.attachCommandLine(
            connectCommand: "ssh root@example.test",
            session: "uc-bridge-test",
            directory: nil,
            bridge: bridge
        )

        XCTAssertNotNil(line)
        XCTAssertTrue(line?.contains("ExitOnForwardFailure=no") == true)
        XCTAssertTrue(line?.contains("StreamLocalBindMask=0177") == true)
        XCTAssertTrue(line?.contains("StreamLocalBindUnlink=yes") == true)
        XCTAssertTrue(line?.contains("\(remoteSocket):127.0.0.1:46000") == true)
        XCTAssertFalse(line?.contains("ExitOnForwardFailure=yes") == true)
        XCTAssertTrue(line?.contains("line one\nline two") == true)
    }

    func testRemoteTmuxCommandEscapesDirectoryQuotes() {
        let cmd = UniConnectSSH.remoteTmuxCommand(session: "s1", directory: "/it's/here")
        XCTAssertTrue(cmd.hasPrefix("tmux set-option -g history-limit 50000 \\; new-session -A -s 's1' -c '/it'\\''s/here'"))
        XCTAssertTrue(cmd.contains("set-option -g mouse on"), "wheel scrolling inside tmux")
        XCTAssertTrue(cmd.contains("history-limit 50000"))
    }

    func testExistingTmuxCommandChecksThenAttachesWithoutCreatingReplacement() {
        let cmd = UniConnectSSH.remoteExistingTmuxCommand(session: "saved-session")

        XCTAssertTrue(cmd.contains("tmux has-session -t '=saved-session'"))
        XCTAssertTrue(cmd.contains("exec tmux attach-session -t '=saved-session'"))
        XCTAssertTrue(cmd.contains("set-option -g mouse on"))
        XCTAssertTrue(cmd.contains("history-limit 50000"))
        XCTAssertFalse(cmd.contains("new-session"))
        XCTAssertFalse(cmd.contains(" -A "))
    }

    func testExistingTmuxAttachCommandLineCannotCreateMissingSavedSession() throws {
        let line = try XCTUnwrap(UniConnectSSH.attachCommandLine(
            connectCommand: "ssh root@1.2.3.4",
            session: "saved-session",
            directory: nil,
            existingSessionOnly: true
        ))

        XCTAssertTrue(line.contains("tmux has-session"))
        XCTAssertTrue(line.contains("tmux attach-session"))
        XCTAssertFalse(line.contains("tmux new-session"))
        XCTAssertFalse(line.contains(" -A "))
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
        XCTAssertTrue(contents.contains("export HOME="))
        XCTAssertTrue(contents.contains("export PATH=/usr/bin:/bin:/usr/sbin:/sbin"))
        XCTAssertTrue(contents.contains("unset SSHPASS SSH_ASKPASS"))
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

    @MainActor
    func testReleaseLockPolicyIgnoresEnvironmentAndDefaultsDisableEscapes() {
        XCTAssertTrue(
            UniConnectAppLock.resolvedIsEnabled(
                allowsDevelopmentOverrides: false,
                environment: [
                    "UNICONNECT_DISABLE_LOCK": "1",
                    "XCTestConfigurationFilePath": "/tmp/fake.xctestconfiguration",
                ],
                persistedOverride: false
            ),
            "Release must remain locked even when development escape values are present"
        )
        XCTAssertFalse(
            UniConnectAppLock.resolvedIsEnabled(
                allowsDevelopmentOverrides: true,
                environment: ["UNICONNECT_DISABLE_LOCK": "1"],
                persistedOverride: true
            )
        )
        XCTAssertFalse(
            UniConnectAppLock.resolvedIsEnabled(
                allowsDevelopmentOverrides: true,
                environment: [:],
                persistedOverride: false
            )
        )
    }

    @MainActor
    func testLockedShortcutGateConsumesNewBoxCommandPaletteAndReconnect() throws {
        let quitShortcut = KeyboardShortcutSettings.Action.quit.defaultShortcut
        let cases: [(NSEvent.ModifierFlags, String, UInt16)] = [
            ([.command], "n", 45),
            ([.command, .shift], "p", 35),
            ([.command], "r", 15),
        ]

        for (flags, characters, keyCode) in cases {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            ))
            XCTAssertEqual(
                UniConnectAppLock.lockedShortcutDecision(
                    isLocked: true,
                    event: event,
                    quitShortcut: quitShortcut
                ),
                .consume,
                "\(flags.rawValue)+\(characters) must not reach its mutating shortcut while locked"
            )
            XCTAssertEqual(
                UniConnectAppLock.lockedShortcutDecision(
                    isLocked: false,
                    event: event,
                    quitShortcut: quitShortcut
                ),
                .passThrough
            )
        }
    }

    @MainActor
    func testLockedShortcutGateKeepsOnlyUnlockAndQuitAvailable() throws {
        func event(flags: NSEvent.ModifierFlags, characters: String, keyCode: UInt16) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            ))
        }
        let quitShortcut = KeyboardShortcutSettings.Action.quit.defaultShortcut

        XCTAssertEqual(
            UniConnectAppLock.lockedShortcutDecision(
                isLocked: true,
                event: try event(flags: [], characters: "\r", keyCode: 36),
                quitShortcut: quitShortcut
            ),
            .authenticate
        )
        XCTAssertEqual(
            UniConnectAppLock.lockedShortcutDecision(
                isLocked: true,
                event: try event(flags: [.command], characters: "q", keyCode: 12),
                quitShortcut: quitShortcut
            ),
            .terminate
        )
    }

    @MainActor
    func testLockedTargetActionPolicyRejectsMutationAndAllowsOnlyExitOrLockSurface() {
        XCTAssertTrue(
            UniConnectAppLock.shouldConsumeApplicationAction(
                isLocked: true,
                isTerminationAction: false,
                isQuitMenuItem: false,
                originatesInLockSurface: false
            )
        )
        XCTAssertFalse(
            UniConnectAppLock.shouldConsumeApplicationAction(
                isLocked: true,
                isTerminationAction: true,
                isQuitMenuItem: false,
                originatesInLockSurface: false
            )
        )
        XCTAssertFalse(
            UniConnectAppLock.shouldConsumeApplicationAction(
                isLocked: true,
                isTerminationAction: false,
                isQuitMenuItem: true,
                originatesInLockSurface: false
            )
        )
        XCTAssertFalse(
            UniConnectAppLock.shouldConsumeApplicationAction(
                isLocked: true,
                isTerminationAction: false,
                isQuitMenuItem: false,
                originatesInLockSurface: true
            )
        )
    }

#if DEBUG
    @MainActor
    func testLockedApplicationSendActionBlocksMenuClickButAllowsQuitMenuClick() {
        AppDelegate.installWindowResponderSwizzlesForTesting()
        let lock = UniConnectAppLock.shared
        lock.resetForTesting()
        lock.presentsWindows = false
        lock.enabledOverride = true
        lock.lock()
        defer { lock.resetForTesting() }

        let probe = LockMenuActionProbe()
        let mutationItem = NSMenuItem(title: "mutation", action: #selector(LockMenuActionProbe.invoke(_:)), keyEquivalent: "")
        mutationItem.target = probe
        XCTAssertTrue(NSApp.sendAction(mutationItem.action!, to: probe, from: mutationItem))
        XCTAssertEqual(probe.invocationCount, 0, "a menu click must be consumed before its mutation runs")

        let quitItem = NSMenuItem(
            title: String(localized: "menu.app.quitUniConnect", defaultValue: "Quit UniConnect"),
            action: #selector(LockMenuActionProbe.invoke(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = probe
        XCTAssertTrue(NSApp.sendAction(quitItem.action!, to: probe, from: quitItem))
        XCTAssertEqual(probe.invocationCount, 1, "the explicit Quit menu action remains available")
    }

    @MainActor
    func testLockedShortcutMonitorStopsMutationBeforeAppRouting() throws {
        let appDelegate = try XCTUnwrap(AppDelegate.shared)
        let originalTabManager = appDelegate.tabManager
        let tabManager = TabManager()
        appDelegate.tabManager = tabManager

        let lock = UniConnectAppLock.shared
        lock.resetForTesting()
        lock.presentsWindows = false
        lock.enabledOverride = true
        lock.lock()

        let paletteRequests = LockNotificationProbe()
        let paletteObserver = NotificationCenter.default.addObserver(
            forName: .commandPaletteRequested,
            object: nil,
            queue: .main
        ) { _ in
            paletteRequests.count += 1
        }
        defer {
            NotificationCenter.default.removeObserver(paletteObserver)
            appDelegate.tabManager = originalTabManager
            lock.resetForTesting()
        }

        let initialWorkspaceCount = tabManager.tabs.count
        let shortcuts: [(NSEvent.ModifierFlags, String, UInt16)] = [
            ([.command], "n", 45),
            ([.command, .shift], "p", 35),
            ([.command], "r", 15),
        ]
        for (flags, characters, keyCode) in shortcuts {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            ))
            XCTAssertTrue(appDelegate.debugHandleShortcutMonitorEvent(event: event))
        }

        XCTAssertEqual(tabManager.tabs.count, initialWorkspaceCount)
        XCTAssertEqual(paletteRequests.count, 0)
    }
#endif

    @MainActor
    func testLockDismissesPopUpMenuPanelsBeforeShowingCover() {
        let normalWindow = LockWindowDismissalProbe(
            contentRect: NSRect(x: 0, y: 0, width: 20, height: 20),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let popUpWindow = LockWindowDismissalProbe(
            contentRect: NSRect(x: 0, y: 0, width: 20, height: 20),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        normalWindow.level = .floating
        popUpWindow.level = .popUpMenu
        popUpWindow.isFloatingPanel = true
        popUpWindow.collectionBehavior = [.transient]
        normalWindow.addChildWindow(popUpWindow, ordered: .above)
        defer {
            if popUpWindow.parent === normalWindow {
                normalWindow.removeChildWindow(popUpWindow)
            }
            popUpWindow.close()
            normalWindow.close()
        }

        XCTAssertEqual(
            UniConnectAppLock.dismissTransientPopUpWindows([normalWindow, popUpWindow]),
            1
        )
        XCTAssertEqual(normalWindow.orderOutCount, 0)
        XCTAssertEqual(popUpWindow.orderOutCount, 1)
        XCTAssertNil(popUpWindow.parent)
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
        let secret = ["s3cr3t", "fragment", "for", "test"].joined(separator: "-")
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
    func testPersistNowWritesReadableSecretFreeJSONWithImmutableVaultCompanions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-readable-backup-\(UUID().uuidString)", isDirectory: true)
        let historyDirectory = directory.appendingPathComponent("history", isDirectory: true)
        let backupURL = directory.appendingPathComponent("backup.json")
        let vaultURL = directory.appendingPathComponent("live-vault.uc")
        defer { try? FileManager.default.removeItem(at: directory) }

        let key = SymmetricKey(size: .bits256)
        let vault = UniConnectVault(storageURL: vaultURL, keyProvider: { key })
        let credentialID = UUID()
        let firstCommand = "sshpass -p 'first-secret' ssh ops@first.example.test"
        let firstTarget = try XCTUnwrap(UniConnectSSHEffectiveTarget(
            user: "ops",
            host: "203.0.113.10",
            port: 2201
        ))
        try vault.storeOrThrow(
            connectCommand: firstCommand,
            effectiveTarget: firstTarget,
            id: credentialID
        )
        let firstVault = try XCTUnwrap(
            vault.encryptedSnapshot(requiring: Set([credentialID]))
        )
        let savedAt = Date(timeIntervalSince1970: 2_000_000)
        var document = UniConnectDocument(
            workspaces: [
                .init(
                    id: UUID(),
                    name: "Production",
                    kind: .ssh,
                    color: "#123456",
                    group: "Servers",
                    isPinned: true,
                    cwd: "/srv/must-not-become-local",
                    connect: firstCommand,
                    credentialId: credentialID,
                    windows: [
                        .init(
                            name: "API logs",
                            tmux: "uc-api",
                            claudeSession: nil,
                            cwd: "/srv/app",
                            isPinned: true
                        ),
                    ]
                ),
                .init(
                    id: UUID(),
                    name: "Local project",
                    kind: .local,
                    color: nil,
                    group: nil,
                    isPinned: nil,
                    cwd: "/Users/test/Projects/Local",
                    connect: nil,
                    windows: [
                        .init(
                            name: "Claude review",
                            tmux: nil,
                            claudeSession: "11111111-2222-3333-4444-555555555555",
                            cwd: "/Users/test/Projects/Local/Sources",
                            isPinned: nil
                        ),
                    ]
                ),
            ],
            savedAt: savedAt
        )

        try UniConnectBackup.persistLocalBackup(
            document: document,
            encryptedVault: firstVault,
            to: backupURL,
            historyDirectory: historyDirectory,
            vault: vault,
            now: savedAt
        )

        let firstManifestData = try Data(contentsOf: backupURL)
        let firstManifestText = String(decoding: firstManifestData, as: UTF8.self)
        let firstManifest = try JSONDecoder().decode(
            UniConnectBackup.LocalBackupManifest.self,
            from: firstManifestData
        )
        let firstCompanionName = try XCTUnwrap(firstManifest.vaultFile)
        XCTAssertEqual(firstManifest.vaultSHA256?.count, 64)
        let firstCompanionURL = directory.appendingPathComponent(firstCompanionName)
        XCTAssertNil(firstManifest.document.workspaces[0].connect)
        XCTAssertNil(firstManifest.document.workspaces[0].cwd)
        XCTAssertNil(firstManifest.document.workspaces[0].windows[0].cwd)
        XCTAssertEqual(firstManifest.document.workspaces[0].credentialId, credentialID)
        XCTAssertEqual(
            firstManifest.document.workspaces[1].windows[0].cwd,
            "/Users/test/Projects/Local/Sources"
        )
        XCTAssertTrue(firstManifestText.contains("Production"))
        XCTAssertTrue(firstManifestText.contains("API logs"))
        XCTAssertTrue(firstManifestText.contains("uc-api"))
        XCTAssertTrue(firstManifestText.contains(credentialID.uuidString))
        XCTAssertTrue(firstManifestText.contains("11111111-2222-3333-4444-555555555555"))
        XCTAssertFalse(firstManifestText.contains("first-secret"))
        XCTAssertFalse(firstManifestText.localizedCaseInsensitiveContains("sshpass"))
        XCTAssertFalse(firstManifestText.contains("first.example.test"))
        XCTAssertFalse(firstManifestText.contains("/srv/must-not-become-local"))
        XCTAssertFalse(firstManifestText.contains("/srv/app"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstCompanionURL.path))
        XCTAssertFalse(
            String(decoding: try Data(contentsOf: firstCompanionURL), as: UTF8.self)
                .contains("first-secret")
        )

        let firstHistoryURL = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: historyDirectory,
                includingPropertiesForKeys: nil
            ).first(where: { $0.pathExtension == "json" })
        )

        let secondCommand = "sshpass -p 'second-secret' ssh ops@second.example.test"
        let secondTarget = try XCTUnwrap(UniConnectSSHEffectiveTarget(
            user: "ops",
            host: "203.0.113.20",
            port: 2202
        ))
        try vault.storeOrThrow(
            connectCommand: secondCommand,
            effectiveTarget: secondTarget,
            id: credentialID
        )
        let secondVault = try XCTUnwrap(
            vault.encryptedSnapshot(requiring: Set([credentialID]))
        )
        document.workspaces[0].connect = secondCommand
        try UniConnectBackup.persistLocalBackup(
            document: document,
            encryptedVault: secondVault,
            to: backupURL,
            historyDirectory: historyDirectory,
            vault: vault,
            now: savedAt.addingTimeInterval(60)
        )

        let current = try UniConnectBackup.readReadableBackup(at: backupURL, vault: vault)
        XCTAssertEqual(current.workspaces.first?.connect, secondCommand)
        XCTAssertEqual(current.workspaces.first?.credentialId, credentialID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstCompanionURL.path))

        // The first history pair remains permanently bound to revision A even though
        // the live vault now maps the same test ID to B.
        let historical = try UniConnectBackup.readReadableBackup(at: firstHistoryURL, vault: vault)
        XCTAssertEqual(historical.workspaces.first?.connect, firstCommand)
        XCTAssertEqual(historical.workspaces.first?.credentialId, credentialID)
        guard case .plain(let importSource) = try UniConnectBackup.inspectDetailed(
            at: firstHistoryURL,
            vault: vault
        ) else {
            return XCTFail("expected readable backup import source")
        }
        XCTAssertEqual(importSource.document, historical)
        XCTAssertEqual(
            importSource.sshCredentialRecordsByWorkspaceIndex[0],
            UniConnectSSHCredentialRecord(
                connectCommand: firstCommand,
                effectiveTarget: firstTarget
            )
        )
        XCTAssertNotEqual(
            importSource.sshCredentialRecordsByWorkspaceIndex[0]?.effectiveTarget,
            secondTarget
        )

        let currentManifest = try JSONDecoder().decode(
            UniConnectBackup.LocalBackupManifest.self,
            from: Data(contentsOf: backupURL)
        )
        let currentCompanion = directory.appendingPathComponent(
            try XCTUnwrap(currentManifest.vaultFile)
        )
        let historicalManifest = try JSONDecoder().decode(
            UniConnectBackup.LocalBackupManifest.self,
            from: Data(contentsOf: firstHistoryURL)
        )
        let historicalCompanion = historyDirectory.appendingPathComponent(
            try XCTUnwrap(historicalManifest.vaultFile)
        )
        try UniConnectAtomicFileWriter.write(
            Data(contentsOf: historicalCompanion),
            to: currentCompanion
        )
        XCTAssertThrowsError(
            try UniConnectBackup.readReadableBackup(at: backupURL, vault: vault)
        )
        try FileManager.default.removeItem(at: currentCompanion)
        XCTAssertThrowsError(
            try UniConnectBackup.readReadableBackup(at: backupURL, vault: vault)
        )
    }

    @MainActor
    func testReadableBackupRejectsMissingCredentialRevisionBeforeWriting() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-incomplete-backup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        let vault = UniConnectVault(
            storageURL: directory.appendingPathComponent("vault.uc"),
            keyProvider: { key }
        )
        let document = UniConnectDocument(workspaces: [
            .init(
                name: "Unrecoverable",
                kind: .ssh,
                color: nil,
                group: nil,
                isPinned: nil,
                cwd: nil,
                connect: "ssh ops@example.test",
                credentialId: UUID(),
                windows: [.init(name: "shell", tmux: "uc-shell", claudeSession: nil, cwd: nil, isPinned: nil)]
            ),
        ])
        let backupURL = directory.appendingPathComponent("backup.json")

        XCTAssertThrowsError(try UniConnectBackup.persistLocalBackup(
            document: document,
            encryptedVault: nil,
            to: backupURL,
            historyDirectory: directory.appendingPathComponent("history", isDirectory: true),
            vault: vault
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
    }

    @MainActor
    func testHistoryCleanupKeepsVaultWhenMarkerIsADanglingSymlink() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-history-dangling-marker-\(UUID().uuidString)", isDirectory: true)
        let historyDirectory = directory.appendingPathComponent("history", isDirectory: true)
        let target = directory.appendingPathComponent("backup.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let stem = "backup-protected"
        let companion = historyDirectory.appendingPathComponent("\(stem).vault.uc")
        let marker = historyDirectory.appendingPathComponent("\(stem).json")
        try UniConnectAtomicFileWriter.write(Data("encrypted-vault".utf8), to: companion)
        try FileManager.default.createSymbolicLink(
            at: marker,
            withDestinationURL: historyDirectory.appendingPathComponent("missing.json")
        )
        let vault = UniConnectVault(
            storageURL: directory.appendingPathComponent("live-vault.uc"),
            keyProvider: { SymmetricKey(size: .bits256) }
        )

        _ = try UniConnectBackup.persistLocalBackup(
            document: UniConnectDocument(workspaces: []),
            encryptedVault: nil,
            to: target,
            historyDirectory: historyDirectory,
            vault: vault,
            now: Date(timeIntervalSince1970: 2_000_000)
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: companion.path))
        XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(atPath: marker.path))
    }

    @MainActor
    func testLegacyWholeDocumentBackupMigratesWithoutDeletingItsRollbackSource() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-legacy-backup-\(UUID().uuidString)", isDirectory: true)
        let historyDirectory = directory.appendingPathComponent("history", isDirectory: true)
        let readableURL = directory.appendingPathComponent("backup.json")
        let legacyURL = directory.appendingPathComponent("backup.uc")
        defer { try? FileManager.default.removeItem(at: directory) }

        let key = SymmetricKey(size: .bits256)
        let vault = UniConnectVault(
            storageURL: directory.appendingPathComponent("live-vault.uc"),
            keyProvider: { key }
        )
        let command = "sshpass -p 'legacy-secret' ssh root@legacy.example.test"
        let legacyDocument = UniConnectDocument(
            workspaces: [
                .init(
                    id: UUID(),
                    name: "Legacy VPS",
                    kind: .ssh,
                    color: nil,
                    group: nil,
                    isPinned: nil,
                    cwd: nil,
                    connect: command,
                    windows: [
                        .init(name: "worker", tmux: "uc-worker", claudeSession: nil, cwd: nil, isPinned: nil),
                    ]
                ),
            ],
            savedAt: Date(timeIntervalSince1970: 1_900_000)
        )
        let plaintext = try JSONEncoder().encode(legacyDocument)
        try UniConnectAtomicFileWriter.write(
            try UniConnectCrypto.seal(plaintext, key: key),
            to: legacyURL
        )

        let migrated = try UniConnectBackup.readLocalBackup(
            readableURL: readableURL,
            legacyURL: legacyURL,
            historyDirectory: historyDirectory,
            vault: vault,
            now: Date(timeIntervalSince1970: 2_000_000),
            legacyKey: key
        )

        XCTAssertEqual(migrated.workspaces.first?.connect, command)
        XCTAssertNotNil(migrated.workspaces.first?.credentialId)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: readableURL.path))
        let readableText = String(decoding: try Data(contentsOf: readableURL), as: UTF8.self)
        XCTAssertTrue(readableText.contains("Legacy VPS"))
        XCTAssertTrue(readableText.contains("uc-worker"))
        XCTAssertFalse(readableText.contains("legacy-secret"))
        XCTAssertFalse(readableText.localizedCaseInsensitiveContains("sshpass"))
        XCTAssertFalse(readableText.contains("legacy.example.test"))

        // Prove the migrated pair is independently recoverable before removing the
        // old source in this isolated test fixture. Production intentionally retains it.
        try FileManager.default.removeItem(at: legacyURL)
        let reread = try UniConnectBackup.readLocalBackup(
            readableURL: readableURL,
            legacyURL: legacyURL,
            historyDirectory: historyDirectory,
            vault: vault,
            legacyKey: key
        )
        XCTAssertEqual(reread, migrated)
    }

    @MainActor
    func testAppOwnedPlainStartupSeedIsReplacedByReadableSplitStorage() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-startup-seed-\(UUID().uuidString)", isDirectory: true)
        let seedURL = directory.appendingPathComponent("seed.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let key = SymmetricKey(size: .bits256)
        let vault = UniConnectVault(
            storageURL: directory.appendingPathComponent("live-vault.uc"),
            keyProvider: { key }
        )
        let command = "sshpass -p 'seed-secret' ssh ops@seed.example.test"
        let document = UniConnectDocument(workspaces: [
            .init(
                id: UUID(),
                name: "Seed VPS",
                kind: .ssh,
                color: nil,
                group: nil,
                isPinned: nil,
                cwd: "/srv/project",
                connect: command,
                windows: [
                    .init(name: "chatbot", tmux: "seed-chatbot", claudeSession: nil, cwd: "/srv/project/app", isPinned: nil),
                ]
            ),
            .init(
                id: UUID(),
                name: "Incomplete row",
                kind: .ssh,
                color: nil,
                group: nil,
                isPinned: nil,
                cwd: nil,
                connect: nil,
                windows: []
            ),
        ])
        try UniConnectAtomicFileWriter.write(try JSONEncoder().encode(document), to: seedURL)

        let markerData = try UniConnectBackup.securePlainStartupSeed(
            document: document,
            at: seedURL,
            vault: vault
        )
        let onDisk = try Data(contentsOf: seedURL)
        let text = String(decoding: onDisk, as: UTF8.self)
        XCTAssertEqual(markerData, onDisk)
        XCTAssertTrue(UniConnectBackup.isReadableLocalBackupManifest(onDisk))
        XCTAssertTrue(text.contains("Seed VPS"))
        XCTAssertTrue(text.contains("seed-chatbot"))
        XCTAssertFalse(text.contains("seed-secret"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("sshpass"))
        XCTAssertFalse(text.contains("seed.example.test"))

        let manifest = try JSONDecoder().decode(
            UniConnectBackup.LocalBackupManifest.self,
            from: onDisk
        )
        XCTAssertEqual(
            manifest.document.workspaces[0].windows[0].cwd,
            "/srv/project/app"
        )
        XCTAssertEqual(
            manifest.purpose,
            UniConnectBackup.LocalBackupManifest.startupSeedPurpose
        )
        let restored = try UniConnectBackup.readReadableBackup(at: seedURL, vault: vault)
        XCTAssertEqual(restored.workspaces[0].connect, command)
        XCTAssertEqual(restored.workspaces[0].cwd, "/srv/project")
        XCTAssertEqual(restored.workspaces[0].windows[0].cwd, "/srv/project/app")
        XCTAssertNil(restored.workspaces[1].connect)
        XCTAssertNil(restored.workspaces[1].credentialId)
    }

    @MainActor
    func testHistoricalAppOwnedSeedFilesAreSecuredOnceWithoutFollowingLinks() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-historical-seeds-\(UUID().uuidString)", isDirectory: true)
        let historicalSeed = directory.appendingPathComponent("seed-inicial-2026.json")
        let alreadyScrubbedSeed = directory.appendingPathComponent("seed-scrubbed.json")
        let outsideDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-outside-seed-\(UUID().uuidString)", isDirectory: true)
        let outsideSeed = outsideDirectory.appendingPathComponent("outside.json")
        let linkedSeed = directory.appendingPathComponent("seed-linked.json")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: outsideDirectory)
        }

        let credentialPattern = "sshpass -p 'private-value' ssh root@example.test"
        let document = UniConnectDocument(workspaces: [
            .init(
                name: "Historical VPS",
                kind: .ssh,
                color: nil,
                group: nil,
                isPinned: nil,
                cwd: nil,
                connect: credentialPattern,
                windows: []
            ),
        ])
        let plaintext = try JSONEncoder().encode(document)
        let scrubbedCredentialID = UUID()
        let scrubbedDocument = UniConnectDocument(workspaces: [
            .init(
                name: "Already scrubbed VPS",
                kind: .ssh,
                color: nil,
                group: nil,
                isPinned: nil,
                cwd: nil,
                connect: nil,
                credentialId: scrubbedCredentialID,
                windows: []
            ),
        ])
        let scrubbedData = try JSONEncoder().encode(scrubbedDocument)
        try UniConnectAtomicFileWriter.write(plaintext, to: historicalSeed)
        try UniConnectAtomicFileWriter.write(scrubbedData, to: alreadyScrubbedSeed)
        try UniConnectAtomicFileWriter.write(plaintext, to: outsideSeed)
        try FileManager.default.createSymbolicLink(at: linkedSeed, withDestinationURL: outsideSeed)
        let vault = UniConnectVault(
            storageURL: directory.appendingPathComponent("live-vault.uc"),
            keyProvider: { SymmetricKey(data: Data(repeating: 7, count: 32)) }
        )

        XCTAssertEqual(
            UniConnectBackup.secureAppOwnedStartupSeeds(in: directory, vault: vault),
            1
        )
        let securedData = try UniConnectAtomicFileWriter.readPrivateFile(at: historicalSeed)
        let securedText = String(decoding: securedData, as: UTF8.self)
        XCTAssertFalse(securedText.contains(credentialPattern))
        let manifest = try JSONDecoder().decode(
            UniConnectBackup.LocalBackupManifest.self,
            from: securedData
        )
        let companionName = try XCTUnwrap(manifest.vaultFile)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(companionName).path
            )
        )

        XCTAssertEqual(
            UniConnectBackup.secureAppOwnedStartupSeeds(in: directory, vault: vault),
            0
        )
        XCTAssertEqual(
            try UniConnectAtomicFileWriter.readPrivateFile(at: alreadyScrubbedSeed),
            scrubbedData
        )
        let preservedScrubbedDocument = try JSONDecoder().decode(
            UniConnectDocument.self,
            from: scrubbedData
        )
        XCTAssertEqual(
            preservedScrubbedDocument.workspaces.first?.credentialId,
            scrubbedCredentialID
        )
        XCTAssertEqual(try Data(contentsOf: outsideSeed), plaintext)
        XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(atPath: linkedSeed.path))
    }

    @MainActor
    func testMixedStartupManifestPreservesOpaqueCredentialAndEffectiveTarget() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-mixed-seed-\(UUID().uuidString)", isDirectory: true)
        let seedURL = directory.appendingPathComponent("seed-mixed.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let key = SymmetricKey(size: .bits256)
        let migrationVault = UniConnectVault(
            storageURL: directory.appendingPathComponent("live-vault.uc"),
            keyProvider: { key }
        )
        let sourceVault = UniConnectVault(
            storageURL: directory.appendingPathComponent("source-vault.uc"),
            keyProvider: { key }
        )
        let preservedCredentialID = UUID()
        let preservedTarget = try XCTUnwrap(UniConnectSSHEffectiveTarget(
            user: "deploy",
            host: "198.51.100.42",
            port: 2_222
        ))
        let preservedRecord = UniConnectSSHCredentialRecord(
            connectCommand: "ssh deployment-alias",
            effectiveTarget: preservedTarget
        )
        let sourceCompanion = try XCTUnwrap(sourceVault.encryptedSnapshot(
            including: [preservedCredentialID: preservedRecord]
        ))
        let sourceCompanionName = "seed-mixed-\(UUID().uuidString.lowercased()).vault.uc"
        try UniConnectAtomicFileWriter.write(
            sourceCompanion,
            to: directory.appendingPathComponent(sourceCompanionName)
        )

        let plaintextCommand = "sshpass -p 'new-private-value' ssh ops@new.example.test"
        let document = UniConnectDocument(workspaces: [
            .init(
                name: "Plaintext VPS",
                kind: .ssh,
                color: nil,
                group: nil,
                isPinned: nil,
                cwd: nil,
                connect: plaintextCommand,
                windows: []
            ),
            .init(
                name: "Already secured VPS",
                kind: .ssh,
                color: nil,
                group: nil,
                isPinned: nil,
                cwd: nil,
                connect: nil,
                credentialId: preservedCredentialID,
                windows: []
            ),
        ])
        let sourceHash = SHA256.hash(data: sourceCompanion)
            .map { String(format: "%02x", $0) }
            .joined()
        let sourceManifest = UniConnectBackup.LocalBackupManifest(
            format: UniConnectBackup.LocalBackupManifest.formatName,
            version: UniConnectBackup.LocalBackupManifest.currentVersion,
            purpose: UniConnectBackup.LocalBackupManifest.startupSeedPurpose,
            vaultFile: sourceCompanionName,
            vaultSHA256: sourceHash,
            document: document
        )
        try UniConnectAtomicFileWriter.write(
            try JSONEncoder().encode(sourceManifest),
            to: seedURL
        )

        XCTAssertEqual(
            UniConnectBackup.secureAppOwnedStartupSeeds(
                in: directory,
                vault: migrationVault
            ),
            1
        )

        let securedData = try UniConnectAtomicFileWriter.readPrivateFile(at: seedURL)
        let securedText = String(decoding: securedData, as: UTF8.self)
        XCTAssertFalse(securedText.contains(plaintextCommand))
        XCTAssertFalse(securedText.contains(preservedRecord.connectCommand))
        XCTAssertFalse(securedText.contains(preservedTarget.host))
        let securedManifest = try JSONDecoder().decode(
            UniConnectBackup.LocalBackupManifest.self,
            from: securedData
        )
        XCTAssertNotNil(securedManifest.document.workspaces[0].credentialId)
        XCTAssertEqual(
            securedManifest.document.workspaces[1].credentialId,
            preservedCredentialID
        )

        let restored = try UniConnectBackup.readReadableBackupSource(
            at: seedURL,
            vault: migrationVault
        )
        XCTAssertEqual(restored.document.workspaces[0].connect, plaintextCommand)
        XCTAssertEqual(
            restored.document.workspaces[1].connect,
            preservedRecord.connectCommand
        )
        XCTAssertEqual(
            restored.sshCredentialRecordsByWorkspaceIndex[1],
            preservedRecord
        )
    }

    @MainActor
    func testMixedStartupManifestWithMissingOpaqueCredentialRemainsByteIdentical() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uniconnect-missing-mixed-seed-\(UUID().uuidString)", isDirectory: true)
        let seedURL = directory.appendingPathComponent("seed-missing.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let key = SymmetricKey(size: .bits256)
        let migrationVault = UniConnectVault(
            storageURL: directory.appendingPathComponent("live-vault.uc"),
            keyProvider: { key }
        )
        let sourceVault = UniConnectVault(
            storageURL: directory.appendingPathComponent("source-vault.uc"),
            keyProvider: { key }
        )
        let unrelatedCredentialID = UUID()
        let unrelatedRecord = UniConnectSSHCredentialRecord(
            connectCommand: "ssh unrelated-alias",
            effectiveTarget: try XCTUnwrap(UniConnectSSHEffectiveTarget(
                user: "other",
                host: "203.0.113.9",
                port: 22
            ))
        )
        let sourceCompanion = try XCTUnwrap(sourceVault.encryptedSnapshot(
            including: [unrelatedCredentialID: unrelatedRecord]
        ))
        let sourceCompanionName = "seed-missing-\(UUID().uuidString.lowercased()).vault.uc"
        try UniConnectAtomicFileWriter.write(
            sourceCompanion,
            to: directory.appendingPathComponent(sourceCompanionName)
        )

        let missingCredentialID = UUID()
        let document = UniConnectDocument(workspaces: [
            .init(
                name: "Plaintext VPS",
                kind: .ssh,
                color: nil,
                group: nil,
                isPinned: nil,
                cwd: nil,
                connect: "ssh ops@plain.example.test",
                windows: []
            ),
            .init(
                name: "Missing secured VPS",
                kind: .ssh,
                color: nil,
                group: nil,
                isPinned: nil,
                cwd: nil,
                connect: nil,
                credentialId: missingCredentialID,
                windows: []
            ),
        ])
        let sourceHash = SHA256.hash(data: sourceCompanion)
            .map { String(format: "%02x", $0) }
            .joined()
        let sourceManifest = UniConnectBackup.LocalBackupManifest(
            format: UniConnectBackup.LocalBackupManifest.formatName,
            version: UniConnectBackup.LocalBackupManifest.currentVersion,
            purpose: UniConnectBackup.LocalBackupManifest.startupSeedPurpose,
            vaultFile: sourceCompanionName,
            vaultSHA256: sourceHash,
            document: document
        )
        let originalData = try JSONEncoder().encode(sourceManifest)
        try UniConnectAtomicFileWriter.write(originalData, to: seedURL)
        let originalNames = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))

        XCTAssertEqual(
            UniConnectBackup.secureAppOwnedStartupSeeds(
                in: directory,
                vault: migrationVault
            ),
            0
        )
        XCTAssertEqual(
            try UniConnectAtomicFileWriter.readPrivateFile(at: seedURL),
            originalData
        )
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
            originalNames
        )
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
        XCTAssertNotNil(UniConnectSSH.validateConnectCommand("/tmp/ssh root@host"))
        XCTAssertNotNil(UniConnectSSH.validateConnectCommand("sshpass -p x /tmp/ssh root@host"))
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
        ssh -i ~/keys/example.pem root@example.test
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
        XCTAssertEqual(ssh.connect, "ssh -i ~/keys/example.pem root@example.test")
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

#if DEBUG
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct UniConnectNativePasswordFallbackTests {
    private final class PendingAuthenticator: UniConnectAuthenticating {
        private(set) var evaluatedPolicies: [LAPolicy] = []
        private var pendingCompletion: ((Bool, Error?) -> Void)?

        func canEvaluate(_ policy: LAPolicy) -> (Bool, LAError.Code?) {
            // The regression requires working Touch ID, not forced biometric lockout.
            (true, nil)
        }

        func evaluate(_ policy: LAPolicy, reason: String, completion: @escaping (Bool, Error?) -> Void) {
            evaluatedPolicies.append(policy)
            pendingCompletion = completion
        }

        func complete(success: Bool, errorCode: LAError.Code? = nil) {
            let completion = pendingCompletion
            pendingCompletion = nil
            completion?(success, errorCode.map { LAError($0) })
        }
    }

    @Test
    func ownerAuthenticationOffersNativePasswordWithAvailableBiometricsAndExplicitFallbacks() {
        let available = UniConnectAuthPolicy.resolve(biometricsAvailable: true, errorCode: nil)
        #expect(available.0 == .deviceOwnerAuthentication)
        #expect(available.1 == nil)
        let fallbackCases: [(LAError.Code?, String)] = [
            (.biometryLockout, String(
                localized: "uniconnect.lock.fallback.lockout",
                defaultValue: "Touch ID is locked after too many attempts. Enter your Mac password."
            )),
            (.biometryNotEnrolled, String(
                localized: "uniconnect.lock.fallback.notEnrolled",
                defaultValue: "No fingerprints are enrolled. Enter your Mac password."
            )),
            (.biometryNotAvailable, String(
                localized: "uniconnect.lock.fallback.notAvailable",
                defaultValue: "This Mac does not have Touch ID. Enter your Mac password."
            )),
            (nil, String(
                localized: "uniconnect.lock.fallback.unavailable",
                defaultValue: "Touch ID is unavailable. Enter your Mac password."
            )),
        ]
        for (code, expectedReason) in fallbackCases {
            let (policy, reason) = UniConnectAuthPolicy.resolve(biometricsAvailable: false, errorCode: code)
            #expect(policy == .deviceOwnerAuthentication)
            #expect(reason == expectedReason)
        }
    }

    @Test
    func successfulOwnerAuthenticationUnlocksOnlyCurrentGate() async {
        let (lock, authenticator) = makeLock()
        defer { lock.resetForTesting() }
        lock.lock()
        lock.authenticate()
        #expect(lock.isLocked)
        #expect(lock.isAuthenticating)
        #expect(authenticator.evaluatedPolicies == [.deviceOwnerAuthentication])

        authenticator.complete(success: true)
        await waitForEvaluationCompletion(lock)
        #expect(!lock.isLocked)
        #expect(lock.lastError == nil)

        lock.lock()
        #expect(lock.isLocked)
        #expect(UniConnectAppLock.resolvedIsEnabled(
            allowsDevelopmentOverrides: false,
            environment: ["UNICONNECT_DISABLE_LOCK": "1"],
            persistedOverride: false
        ))
        lock.authenticate()
        #expect(lock.isLocked)
        #expect(authenticator.evaluatedPolicies == [.deviceOwnerAuthentication, .deviceOwnerAuthentication])
        authenticator.complete(success: true)
        await waitForEvaluationCompletion(lock)
        #expect(!lock.isLocked)
    }

    @Test(arguments: [LAError.Code.userCancel, .systemCancel, .authenticationFailed])
    func cancellationOrFailureKeepsGateLockedAndAllowsAuthenticatedRetry(errorCode: LAError.Code) async {
        let (lock, authenticator) = makeLock()
        defer { lock.resetForTesting() }
        lock.lock()
        lock.authenticate()
        #expect(authenticator.evaluatedPolicies == [.deviceOwnerAuthentication])

        authenticator.complete(success: false, errorCode: errorCode)
        await waitForEvaluationCompletion(lock)
        #expect(lock.isLocked)
        #expect(!lock.isAuthenticating)
        #expect(lock.lastError != nil)

        lock.authenticate()
        #expect(lock.isLocked)
        authenticator.complete(success: true)
        await waitForEvaluationCompletion(lock)
        #expect(!lock.isLocked)
        #expect(authenticator.evaluatedPolicies.count == 2)
    }

    @Test
    func sensitiveActionUsesSameOwnerPolicyAndRejectsCancellation() async {
        let (lock, authenticator) = makeLock()
        defer { lock.resetForTesting() }
        let outcome: Bool = await withCheckedContinuation { continuation in
            lock.authenticateForSensitiveAction(reason: "Synthetic sensitive-action authentication") {
                continuation.resume(returning: $0)
            }
            #expect(authenticator.evaluatedPolicies == [.deviceOwnerAuthentication])
            authenticator.complete(success: false, errorCode: .userCancel)
        }
        #expect(!outcome)
    }

    private func makeLock() -> (UniConnectAppLock, PendingAuthenticator) {
        let lock = UniConnectAppLock.shared
        lock.resetForTesting()
        let authenticator = PendingAuthenticator()
        lock.authenticator = authenticator
        lock.presentsWindows = false
        lock.enabledOverride = true
        return (lock, authenticator)
    }

    private func waitForEvaluationCompletion(_ lock: UniConnectAppLock) async {
        // Observe the existing legacy publisher as an AsyncSequence; no sleeps or polling.
        // The MainActor evaluation callback finishes its synchronous unlock before resuming us.
        for await authenticating in lock.$isAuthenticating.values {
            if !authenticating { return }
        }
    }
}
#endif
