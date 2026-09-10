import Foundation
import os

/// Agarre sobre el hijo que corre ahora mismo, para poder matarlo desde fuera.
///
/// Existe porque el manejador de cancelación de una tarea es síncrono y no puede esperar al
/// actor: cuando el móvil cuelga o se agota el presupuesto, la señal tiene que salir en ese
/// mismo instante. Se señala al GRUPO del hijo, no solo al hijo, para que un nieto no
/// sobreviva a su padre; el grupo existe porque ``MobileTranscriptionSpawner`` le abre sesión
/// propia, y por eso su identificador es el del propio hijo y la señal no alcanza a nadie más.
final class MobileTranscriptionProcessHandle: @unchecked Sendable {
    private struct State {
        var identifier: pid_t?
        var didFinish = false
        var wasCancelled = false
    }

    // Carve-out de lock: `terminate()` llega desde el manejador de cancelación, síncrono y
    // fuera de todo contexto async, y compite con el arranque y con el fin del hijo por un par
    // de banderas. Un actor solo añadiría saltos de tarea a un compara-y-cambia.
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let escalation: Duration
    private let clock: any Clock<Duration>

    /// - Parameters:
    ///   - escalation: Espera entre `SIGTERM` y `SIGKILL`.
    ///   - clock: Reloj de esa espera; los tests pasan uno virtual.
    init(escalation: Duration = .seconds(2), clock: any Clock<Duration> = ContinuousClock()) {
        self.escalation = escalation
        self.clock = clock
    }

    /// `true` si ya se pidió matar al hijo.
    var isCancelled: Bool {
        state.withLock { $0.wasCancelled }
    }

    /// Registra el hijo recién arrancado.
    ///
    /// - Parameter identifier: Identificador del hijo, que es también el de su grupo.
    /// - Returns: `false` si la cancelación llegó antes de arrancar; entonces el grupo ya ha
    ///   recibido la señal y quien llama solo tiene que recoger al hijo.
    func attach(_ identifier: pid_t) -> Bool {
        let accepted = state.withLock { current -> Bool in
            guard !current.wasCancelled else { return false }
            current.identifier = identifier
            return true
        }
        if !accepted {
            Self.signalGroup(identifier, SIGKILL)
        }
        return accepted
    }

    /// Marca al hijo como terminado y recogido, para que la escalada a `SIGKILL` no dispare
    /// sobre un identificador que el sistema ya puede haber reutilizado.
    func finish() {
        state.withLock { current in
            current.didFinish = true
        }
    }

    /// Manda `SIGTERM` al grupo del hijo y programa `SIGKILL` si sigue vivo tras la escalada.
    func terminate() {
        let identifier = state.withLock { current -> pid_t? in
            current.wasCancelled = true
            guard !current.didFinish else { return nil }
            return current.identifier
        }
        guard let identifier else { return }
        Self.signalGroup(identifier, SIGTERM)
        Task.detached { [state, escalation, clock] in
            // Retraso acotado y cancelable: es el plazo entre las dos señales, no un sondeo.
            try? await clock.sleep(for: escalation)
            let pending = state.withLock { current -> pid_t? in
                guard !current.didFinish else { return nil }
                return current.identifier
            }
            guard let pending else { return }
            Self.signalGroup(pending, SIGKILL)
        }
    }

    /// Señala al grupo de procesos cuyo identificador es el del hijo.
    ///
    /// El identificador se comprueba antes de negarlo: `kill(0, …)` alcanzaría al grupo de
    /// UniConnect y `kill(-1, …)` a todo lo que el usuario pueda tocar.
    private static func signalGroup(_ identifier: pid_t, _ signal: Int32) {
        guard identifier > 1 else { return }
        kill(-identifier, signal)
    }
}
