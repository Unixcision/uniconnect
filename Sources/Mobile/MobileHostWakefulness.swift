import Foundation

/// Keeps the Mac awake for as long as a phone is attached to it.
///
/// A laptop on battery sleeps after an hour, and a sleeping Mac is a Mac that stops answering: the
/// phone's connections die, its screen freezes on the last frame it received, and the person on the
/// other side sees a terminal that looks fine and cannot be typed into. Plugged in the system is
/// already set never to sleep, so this matters exactly where it is easy to forget — away from the
/// desk, which is when the phone is the only way in.
///
/// Uses `ProcessInfo`'s activity API rather than an `IOKit` assertion: it is the supported way to
/// say "do not idle-sleep while I am doing this", it is released by letting go of a token, and it
/// survives an unexpected exit without leaving the machine permanently awake.
///
/// Deliberately the weakest option that does the job — `.idleSystemSleepDisabled` lets the **display**
/// switch off while the machine keeps serving. Nothing here keeps a screen lit or a battery draining
/// for its own sake, and the moment the last phone hangs up the token is dropped.
final class MobileHostWakefulness {
    /// The live activity token, or nil when nothing is attached.
    private var token: NSObjectProtocol?
    // Guarda un único token y lo tocan el registro de conexiones y la cola del listener: una
    // sección crítica de una sola referencia, que es el hueco del cerrojo y no un actor.
    private let lock = NSLock()

    /// Matches the awake state to whether anyone is connected.
    ///
    /// - Parameter attachedClients: how many phones are attached right now.
    func update(attachedClients: Int) {
        lock.lock()
        defer { lock.unlock() }
        if attachedClients > 0 {
            guard token == nil else { return }
            token = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled],
                reason: "UniConnect: un móvil está conectado"
            )
        } else {
            guard let live = token else { return }
            ProcessInfo.processInfo.endActivity(live)
            token = nil
        }
    }

    deinit {
        if let live = token { ProcessInfo.processInfo.endActivity(live) }
    }
}
