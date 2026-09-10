import Foundation
import os

/// Agarre sobre el proceso hijo que corre ahora mismo, para poder matarlo desde fuera.
///
/// Existe porque el manejador de cancelación de una tarea es síncrono y no puede esperar al
/// actor: cuando el móvil cuelga o se agota el presupuesto, la señal tiene que salir en ese
/// mismo instante. Se señala al hijo directamente y no a su grupo, porque `Process` no deja
/// abrir sesión propia y `ffmpeg`, `ffprobe` y `whisper-cli` no crean nietos; señalar al
/// grupo sin sesión propia alcanzaría al propio UniConnect.
final class MobileTranscriptionProcessHandle: @unchecked Sendable {
    private struct State {
        var process: Process?
        var identifier: pid_t?
        var didFinish = false
        var wasCancelled = false
    }

    // Carve-out de lock: `terminate()` llega desde el manejador de cancelación, síncrono y
    // fuera de todo contexto async, y compite con el arranque y con el fin del proceso por un
    // par de banderas. Un actor solo añadiría saltos de tarea a un compara-y-cambia.
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

    /// Registra el proceso recién lanzado.
    ///
    /// - Parameter process: Proceso ya en marcha.
    /// - Returns: `false` si la cancelación llegó antes de arrancar; quien llama debe matarlo.
    func attach(_ process: Process) -> Bool {
        let accepted = state.withLock { current -> Bool in
            guard !current.wasCancelled else { return false }
            current.process = process
            current.identifier = process.processIdentifier
            return true
        }
        if !accepted {
            process.terminate()
        }
        return accepted
    }

    /// Marca el proceso como terminado para que la escalada a `SIGKILL` no dispare.
    func finish() {
        state.withLock { current in
            current.didFinish = true
            current.process = nil
        }
    }

    /// Manda `SIGTERM` al hijo y programa `SIGKILL` si sigue vivo pasada la escalada.
    func terminate() {
        let process = state.withLock { current -> Process? in
            current.wasCancelled = true
            guard !current.didFinish else { return nil }
            return current.process
        }
        guard let process else { return }
        process.terminate()
        Task.detached { [state, escalation, clock] in
            // Retraso acotado y cancelable: es el plazo entre las dos señales, no un sondeo.
            try? await clock.sleep(for: escalation)
            let identifier = state.withLock { current -> pid_t? in
                guard !current.didFinish else { return nil }
                return current.identifier
            }
            guard let identifier, identifier > 0 else { return }
            kill(identifier, SIGKILL)
        }
    }
}
