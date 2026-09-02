import AppKit
import SwiftUI
import LocalAuthentication

// MARK: - App lock (Touch ID gate)
//
// UniConnect refuses to show anything until the owner authenticates with Touch ID.
// Locking never touches the underlying workspaces: terminals, SSH and tmux keep
// running; the lock is a full-screen borderless window above everything.

@MainActor
final class UniConnectAppLock: ObservableObject {
    static let shared = UniConnectAppLock()

    @Published private(set) var isLocked = false
    @Published var lastError: String?
    @Published private(set) var isAuthenticating = false

    private var lockWindows: [NSWindow] = []
    private var isLaunchGate = false

    static var isEnabled: Bool {
        // Escape hatch for tests / debugging.
        let env = ProcessInfo.processInfo.environment
        if env["UNICONNECT_DISABLE_LOCK"] == "1" { return false }
        if env["XCTestConfigurationFilePath"] != nil { return false }
        return UserDefaults.standard.object(forKey: "uniconnect.lockEnabled") as? Bool ?? true
    }

    private init() {}

    /// Called at launch. Presents the lock and authenticates immediately.
    func presentLaunchGate() {
        guard Self.isEnabled, !isLocked else {
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
        showLockWindows()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Policy: Touch ID whenever the sensor is available. If the Mac has no biometrics,
    /// or biometry is locked out after too many failures, we fall back to the macOS
    /// account password through the same system dialog. That fallback is announced
    /// on screen; there is never a silent bypass.
    private static func policy() -> (LAPolicy, String?) {
        let probe = LAContext()
        var error: NSError?
        if probe.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            return (.deviceOwnerAuthenticationWithBiometrics, nil)
        }
        let code = LAError.Code(rawValue: error?.code ?? 0)
        let reason: String
        switch code {
        case .biometryLockout: reason = "Touch ID bloqueado por demasiados intentos: se pide la contraseña del Mac."
        case .biometryNotEnrolled: reason = "No hay huellas registradas: se pide la contraseña del Mac."
        case .biometryNotAvailable: reason = "Este Mac no tiene Touch ID: se pide la contraseña del Mac."
        default: reason = "Touch ID no disponible: se pide la contraseña del Mac."
        }
        return (.deviceOwnerAuthentication, reason)
    }

    func authenticate() {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        lastError = nil
        let (policy, fallbackNotice) = Self.policy()
        if let fallbackNotice { lastError = fallbackNotice }
        let context = LAContext()
        context.localizedCancelTitle = "Cancelar"
        context.localizedFallbackTitle = ""
        var error: NSError?
        guard context.canEvaluatePolicy(policy, error: &error) else {
            isAuthenticating = false
            lastError = "No hay ningún método de autenticación disponible: \(error?.localizedDescription ?? "")"
            return
        }
        context.evaluatePolicy(policy, localizedReason: "Desbloquear UniConnect") { [weak self] success, evalError in
            Task { @MainActor in
                guard let self else { return }
                self.isAuthenticating = false
                if success {
                    self.unlock()
                } else {
                    self.lastError = evalError?.localizedDescription ?? "Huella no reconocida"
                }
            }
        }
    }

    /// One-off authentication for sensitive actions (import, revealing a command).
    func authenticateForSensitiveAction(reason: String, completion: @escaping (Bool) -> Void) {
        guard Self.isEnabled else { completion(true); return }
        let (policy, _) = Self.policy()
        let context = LAContext()
        context.localizedCancelTitle = "Cancelar"
        context.localizedFallbackTitle = ""
        var error: NSError?
        guard context.canEvaluatePolicy(policy, error: &error) else {
            completion(false)
            return
        }
        context.evaluatePolicy(policy, localizedReason: reason) { success, _ in
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
            window.level = .screenSaver
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
            Text(lock.isAuthenticating ? "Pon el dedo en el sensor…" : "Bloqueado. Toca para desbloquear con Touch ID.")
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
                    Label("Desbloquear", systemImage: "touchid")
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
                    Text("Salir")
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
            }
            Spacer()
            Text("Las cajas SSH y sus tmux siguen vivos mientras la app está bloqueada.")
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { lock.authenticate() }
    }
}
