import AppKit
import SwiftUI
import LocalAuthentication

// MARK: - App lock (Touch ID gate)
//
// UniConnect refuses to show anything until macOS authenticates the owner.
// Locking never touches the underlying workspaces: terminals, SSH and tmux keep
// running; the lock is a full-screen borderless window above everything.

/// Seam over `LAContext` so the lock flow can be exercised without biometric hardware.
protocol UniConnectAuthenticating {
    func canEvaluate(_ policy: LAPolicy) -> (Bool, LAError.Code?)
    func evaluate(_ policy: LAPolicy, reason: String, completion: @escaping (Bool, Error?) -> Void)
}

/// Production authenticator: a fresh `LAContext` per evaluation.
struct UniConnectLocalAuthenticator: UniConnectAuthenticating {
    func canEvaluate(_ policy: LAPolicy) -> (Bool, LAError.Code?) {
        let context = LAContext()
        var error: NSError?
        let ok = context.canEvaluatePolicy(policy, error: &error)
        return (ok, error.map { LAError.Code(rawValue: $0.code) } ?? nil)
    }
    func evaluate(_ policy: LAPolicy, reason: String, completion: @escaping (Bool, Error?) -> Void) {
        let context = LAContext()
        context.localizedCancelTitle = String(localized: "common.cancel", defaultValue: "Cancel")
        // Keep the system-localized password alternative available. macOS owns
        // credential entry and validation; the app never receives the password.
        context.evaluatePolicy(policy, localizedReason: reason, reply: completion)
    }
}

@MainActor
final class UniConnectAppLock: ObservableObject {
    static let shared = UniConnectAppLock()

    enum LockedShortcutDecision: Equatable {
        case passThrough
        case authenticate
        case terminate
        case consume
    }

#if DEBUG
    /// Injected for tests; production builds always use `UniConnectLocalAuthenticator`.
    var authenticator: any UniConnectAuthenticating = UniConnectLocalAuthenticator()
    /// Tests can keep the lock logic without creating screen-level windows.
    var presentsWindows = true
    /// Tests can force the gate on/off regardless of environment.
    var enabledOverride: Bool?
    var effectiveIsEnabled: Bool { enabledOverride ?? Self.isEnabled }
#else
    private let authenticator: any UniConnectAuthenticating = UniConnectLocalAuthenticator()
    private let presentsWindows = true
    var effectiveIsEnabled: Bool { Self.isEnabled }
#endif

    @Published private(set) var isLocked = false
    @Published var lastError: String?
    @Published private(set) var isAuthenticating = false

    private var lockWindows: [NSWindow] = []
    private var isLaunchGate = false
    private var idleTimer: Timer?

    /// Minutes of user inactivity (no keyboard/mouse events anywhere) before UniConnect locks
    /// itself. 0 disables the timer. Stored in UserDefaults `uniconnect.autoLockMinutes`.
    static var autoLockMinutes: Int {
        get { UserDefaults.standard.object(forKey: "uniconnect.autoLockMinutes") as? Int ?? 0 }
        set { UserDefaults.standard.set(newValue, forKey: "uniconnect.autoLockMinutes") }
    }

    func startIdleWatch() {
        idleTimer?.invalidate()
        guard effectiveIsEnabled else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIdle() }
        }
    }

    private func checkIdle() {
        let minutes = Self.autoLockMinutes
        guard minutes > 0, !isLocked else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .init(rawValue: ~0)!)
        if idle >= Double(minutes) * 60 {
            lock(reason: "inactividad")
        }
    }

    static var isEnabled: Bool {
#if DEBUG
        return resolvedIsEnabled(
            allowsDevelopmentOverrides: true,
            environment: ProcessInfo.processInfo.environment,
            persistedOverride: UserDefaults.standard.object(forKey: "uniconnect.lockEnabled") as? Bool
        )
#else
        // A signed production build must never turn its launch gate into a preference.
        // Development and XCTest keep explicit seams below, but Release is fail-closed.
        return true
#endif
    }

    /// Resolves the development-only escape hatches without weakening Release builds.
    static func resolvedIsEnabled(
        allowsDevelopmentOverrides: Bool,
        environment: [String: String],
        persistedOverride: Bool?
    ) -> Bool {
        guard allowsDevelopmentOverrides else { return true }
        if environment["UNICONNECT_DISABLE_LOCK"] == "1" { return false }
        if environment["XCTestConfigurationFilePath"] != nil { return false }
        return persistedOverride ?? true
    }

    private init() {}

    /// Called at launch. Presents the lock and authenticates immediately.
    func presentLaunchGate() {
        startIdleWatch()
        guard effectiveIsEnabled, !isLocked else {
            scheduleStartupSeed()
            return
        }
        isLaunchGate = true
        lock(reason: "arranque")
        authenticate()
    }

    /// The seed runs a few seconds after the session restore had a chance to finish.
    private func scheduleStartupSeed() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            UniConnectCoordinator.shared.applyStartupSeedIfNeeded()
        }
    }

    /// Manual "Bloquear" action.
    func lock(reason: String = "manual") {
        guard !isLocked else { return }
        isLocked = true
        lastError = nil
        // Keep terminal content out of screen recordings / captures while locked.
        for window in NSApp.windows where !(window is UniConnectLockWindow) {
            window.sharingType = .none
        }
        guard presentsWindows else { return }
        // `.popUpMenu` panels sit above a floating lock cover. Dismiss them
        // synchronously before creating the cover so no completion menu or other
        // transient app content can remain readable over the locked application.
        Self.dismissTransientPopUpWindows(NSApp.windows)
        showLockWindows()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Routes every keyboard entrypoint through the same fail-closed lock policy.
    @discardableResult
    func handleShortcutIfLocked(_ event: NSEvent) -> Bool {
        let decision = Self.lockedShortcutDecision(
            isLocked: isLocked,
            event: event,
            quitShortcut: KeyboardShortcutSettings.shortcut(for: .quit)
        )
        switch decision {
        case .passThrough:
            return false
        case .authenticate:
            authenticate()
            return true
        case .terminate:
            NSApp.terminate(nil)
            return true
        case .consume:
            return true
        }
    }

    /// Decides how an app-level shortcut behaves while the cover is active.
    static func lockedShortcutDecision(
        isLocked: Bool,
        event: NSEvent,
        quitShortcut: StoredShortcut
    ) -> LockedShortcutDecision {
        guard isLocked, event.type == .keyDown else { return .passThrough }
        if quitShortcut.matches(event: event) { return .terminate }

        let flags = ShortcutStroke.normalizedModifierFlags(from: event.modifierFlags)
        if flags.isEmpty, event.keyCode == 36 || event.keyCode == 76 {
            return .authenticate
        }
        return .consume
    }

    /// Rejects AppKit/SwiftUI target-action dispatch outside the lock surface.
    func shouldConsumeApplicationAction(
        _ action: Selector?,
        target: Any?,
        sender: Any?
    ) -> Bool {
        Self.shouldConsumeApplicationAction(
            isLocked: isLocked,
            isTerminationAction: Self.isTerminationAction(action),
            isQuitMenuItem: (sender as? NSMenuItem).map(Self.isQuitMenuItem) ?? false,
            originatesInLockSurface: actionOriginatesInLockSurface(target: target, sender: sender)
        )
    }

    /// Pure policy seam used by the target-action gate and its regression tests.
    static func shouldConsumeApplicationAction(
        isLocked: Bool,
        isTerminationAction: Bool,
        isQuitMenuItem: Bool,
        originatesInLockSurface: Bool
    ) -> Bool {
        isLocked && !isTerminationAction && !isQuitMenuItem && !originatesInLockSurface
    }

    private func actionOriginatesInLockSurface(target: Any?, sender: Any?) -> Bool {
        for candidate in [sender, target] {
            guard let window = Self.window(forActionObject: candidate) else { continue }
            if lockWindows.contains(where: { $0 === window }) { return true }
        }
        return false
    }

    private static func window(forActionObject object: Any?) -> NSWindow? {
        if let window = object as? NSWindow { return window }
        if let windowController = object as? NSWindowController { return windowController.window }
        if let view = object as? NSView { return view.window }
        if let viewController = object as? NSViewController { return viewController.view.window }
        return nil
    }

    private static func isTerminationAction(_ action: Selector?) -> Bool {
        guard let action else { return false }
        return action == #selector(NSApplication.terminate(_:))
    }

    private static func isQuitMenuItem(_ item: NSMenuItem) -> Bool {
        item.title == String(localized: "menu.app.quitUniConnect", defaultValue: "Quit UniConnect")
    }

    /// Hides app-owned panels whose level would otherwise place them above the cover.
    @discardableResult
    static func dismissTransientPopUpWindows(_ windows: [NSWindow]) -> Int {
        var dismissedCount = 0
        for window in windows where shouldDismissTransientPopUpWindow(window) {
            window.parent?.removeChildWindow(window)
            window.orderOut(nil)
            dismissedCount += 1
        }
        return dismissedCount
    }

    private static func shouldDismissTransientPopUpWindow(_ window: NSWindow) -> Bool {
        guard !(window is UniConnectLockWindow) else { return false }
        if window.level == .popUpMenu { return true }

        // AppKit can normalize a child panel's reported level to its parent when
        // `addChildWindow` runs. Preserve the semantic `.popUpMenu` classification
        // used by our completion panel: floating + transient NSPanel.
        guard let panel = window as? NSPanel else { return false }
        return panel.isFloatingPanel && panel.collectionBehavior.contains(.transient)
    }

    /// macOS offers Touch ID first, with its native account-password alternative.
    /// The launch and sensitive-action gates both require a successful system
    /// authentication; choosing a password never disables either gate.
    private func policy() -> (LAPolicy, String?) {
        let (available, code) = authenticator.canEvaluate(.deviceOwnerAuthenticationWithBiometrics)
        return UniConnectAuthPolicy.resolve(biometricsAvailable: available, errorCode: code)
    }

    func authenticate() {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        lastError = nil
        let (policy, fallbackNotice) = self.policy()
        if let fallbackNotice { lastError = fallbackNotice }
        let (canEvaluate, _) = authenticator.canEvaluate(policy)
        guard canEvaluate else {
            isAuthenticating = false
            lastError = String(
                localized: "uniconnect.lock.error.authenticationUnavailable",
                defaultValue: "No authentication method is available."
            )
            return
        }
        authenticator.evaluate(
            policy,
            reason: String(localized: "uniconnect.lock.reason.unlock", defaultValue: "Unlock UniConnect")
        ) { [weak self] success, evalError in
            Task { @MainActor in
                guard let self else { return }
                self.isAuthenticating = false
                if success {
                    self.unlock()
                } else {
                    self.lastError = evalError?.localizedDescription ?? String(
                        localized: "uniconnect.lock.error.fingerprintNotRecognized",
                        defaultValue: "Fingerprint not recognized"
                    )
                }
            }
        }
    }

    /// One-off authentication for sensitive actions (import, revealing a command).
    func authenticateForSensitiveAction(reason: String, completion: @escaping (Bool) -> Void) {
        guard effectiveIsEnabled else { completion(true); return }
        let (policy, _) = self.policy()
        guard authenticator.canEvaluate(policy).0 else {
            completion(false)
            return
        }
        authenticator.evaluate(policy, reason: reason) { success, _ in
            Task { @MainActor in completion(success) }
        }
    }

    private func unlock() {
        let wasLaunchGate = isLaunchGate
        isLocked = false
        isLaunchGate = false
        if wasLaunchGate { scheduleStartupSeed() }
        // Autosave right after unlocking so a crash seconds later loses nothing.
        AppDelegate.shared?.uniConnectRequestSessionSave()
        for window in lockWindows {
            window.orderOut(nil)
        }
        lockWindows.removeAll()
        for window in NSApp.windows where !(window is UniConnectLockWindow) {
            window.sharingType = .readOnly
        }
        // Give focus back to the main window.
        (NSApp.windows.first(where: { $0 is NSPanel == false && $0.isVisible && $0.canBecomeMain }))?.makeKeyAndOrderFront(nil)
    }

    private func showLockWindows() {
        for window in lockWindows { window.orderOut(nil) }
        lockWindows.removeAll()
        for screen in NSScreen.screens {
            let window = UniConnectLockWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            // Above the app's own windows, but below the system Touch ID dialog (a screen-saver
            // level window would hide the sensor prompt in full screen).
            window.level = .floating
            window.isOpaque = true
            window.backgroundColor = NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.08, alpha: 1)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isReleasedWhenClosed = false
            window.hasShadow = false
            window.contentView = NSHostingView(rootView: UniConnectLockView(lock: self))
            window.setFrame(screen.frame, display: true)
            window.makeKeyAndOrderFront(nil)
            lockWindows.append(window)
        }
    }

#if DEBUG
    /// Restores singleton state between tests without exposing a Release bypass.
    func resetForTesting() {
        idleTimer?.invalidate()
        idleTimer = nil
        for window in lockWindows {
            window.orderOut(nil)
            window.close()
        }
        lockWindows.removeAll()
        for window in NSApp.windows where !(window is UniConnectLockWindow) {
            window.sharingType = .readOnly
        }
        isLocked = false
        isLaunchGate = false
        isAuthenticating = false
        lastError = nil
        authenticator = UniConnectLocalAuthenticator()
        presentsWindows = true
        enabledOverride = nil
    }
#endif
}

private final class UniConnectLockWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

struct UniConnectLockView: View {
    @ObservedObject var lock: UniConnectAppLock

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "touchid")
                .font(.system(size: 88, weight: .thin))
                .foregroundStyle(
                    LinearGradient(colors: [Color(red: 1, green: 0.45, blue: 0.35), Color(red: 0.95, green: 0.2, blue: 0.5)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .symbolEffect(.pulse, options: .repeating, isActive: lock.isAuthenticating)
            Text("UniConnect")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(
                lock.isAuthenticating
                    ? String(localized: "uniconnect.lock.authenticating", defaultValue: "Place your finger on the sensor…")
                    : String(localized: "uniconnect.lock.locked", defaultValue: "Locked. Tap to unlock with Touch ID.")
            )
                .font(.system(size: 20, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
            if let error = lock.lastError {
                Text(error)
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(Color(red: 1, green: 0.5, blue: 0.5))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
            HStack(spacing: 16) {
                Button {
                    lock.authenticate()
                } label: {
                    Label(
                        String(localized: "uniconnect.lock.action.unlock", defaultValue: "Unlock"),
                        systemImage: "touchid"
                    )
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.95, green: 0.3, blue: 0.4))
                .keyboardShortcut(.defaultAction)
                .disabled(lock.isAuthenticating)

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Text(String(localized: "uniconnect.lock.action.quit", defaultValue: "Quit"))
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
            }
            Spacer()
            Text(String(
                localized: "uniconnect.lock.sessionsKeepRunning",
                defaultValue: "SSH boxes and their tmux sessions keep running while the app is locked."
            ))
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { lock.authenticate() }
    }
}


/// Pure decision behind the lock screen: which `LAPolicy` to evaluate and what to tell the
/// user. Kept free of `LAContext` so tests can exercise every branch without hardware.
enum UniConnectAuthPolicy {
    static func resolve(biometricsAvailable: Bool, errorCode: LAError.Code?) -> (LAPolicy, String?) {
        if biometricsAvailable { return (.deviceOwnerAuthentication, nil) }
        let reason: String
        switch errorCode {
        case .biometryLockout?:
            reason = String(
                localized: "uniconnect.lock.fallback.lockout",
                defaultValue: "Touch ID is locked after too many attempts. Enter your Mac password."
            )
        case .biometryNotEnrolled?:
            reason = String(
                localized: "uniconnect.lock.fallback.notEnrolled",
                defaultValue: "No fingerprints are enrolled. Enter your Mac password."
            )
        case .biometryNotAvailable?:
            reason = String(
                localized: "uniconnect.lock.fallback.notAvailable",
                defaultValue: "This Mac does not have Touch ID. Enter your Mac password."
            )
        default:
            reason = String(
                localized: "uniconnect.lock.fallback.unavailable",
                defaultValue: "Touch ID is unavailable. Enter your Mac password."
            )
        }
        return (.deviceOwnerAuthentication, reason)
    }
}
