import Foundation
import os

/// Marca de la última salida real de la PTY de una superficie y del inicio de su racha.
///
/// ``noteOutput(byteCount:now:)`` se llama desde el hilo de lectura de Ghostty por cada
/// trozo de bytes, antes del parser VT, así que el trabajo se reduce a un
/// compare-and-set bajo un lock. El eco de teclado (salida justo después de una tecla
/// local) y los redibujados por cambio de tamaño no cuentan como actividad de la IA.
///
/// La salida contada se agrupa en rachas: un hueco de más de ``runBreakGap`` segundos
/// entre dos salidas contadas empieza una racha nueva. Un redibujado de tmux (cualquier
/// `set-option` o `set-hook` del servidor repinta todos sus clientes) es una ráfaga de
/// menos de 100 ms; una IA trabajando escribe sin parar, así que el resolver solo cree
/// a las rachas largas.
final class AgentOutputActivityCell: Sendable {
    /// Lectura inmutable para el ciclo de evaluación.
    struct Snapshot: Equatable, Sendable {
        /// Epoch en segundos de la última salida contada; `nil` si nunca hubo.
        let lastOutputAt: TimeInterval?
        /// Epoch en segundos de la primera salida de la racha que acaba en ``lastOutputAt``;
        /// `nil` si nunca hubo salida.
        let runStartedAt: TimeInterval?
    }

    private struct State: Sendable {
        var lastOutputAt: TimeInterval?
        var runStartedAt: TimeInterval?
        var lastLocalInputAt: TimeInterval?
        var lastResizeAt: TimeInterval?
    }

    /// Ventana tras una tecla local durante la cual la salida se atribuye al eco.
    static let localInputEchoWindow: TimeInterval = 0.25
    /// Ventana tras un cambio de tamaño durante la cual la salida se atribuye al redibujado.
    static let resizeRedrawWindow: TimeInterval = 0.5
    /// Hueco máximo (segundos) entre dos salidas contadas de la misma racha.
    static let runBreakGap: TimeInterval = 1

    // Carve-out de lock: compare-and-set síncrono desde callbacks no async (hilo de E/S de
    // Ghostty y teclado); un actor añadiría un salto de tarea por cada trozo de salida.
    private let state = OSAllocatedUnfairLock(initialState: State())

    init() {}

    /// Registra salida de la PTY salvo que caiga dentro de la ventana de eco o de
    /// redibujado; continúa la racha actual o, tras un hueco de más de ``runBreakGap``,
    /// empieza otra.
    func noteOutput(byteCount: Int, now: TimeInterval = Date().timeIntervalSince1970) {
        guard byteCount > 0 else { return }
        state.withLock { current in
            if let input = current.lastLocalInputAt, now - input < Self.localInputEchoWindow {
                return
            }
            if let resize = current.lastResizeAt, now - resize < Self.resizeRedrawWindow {
                return
            }
            let continuesRun = current.lastOutputAt.map { now - $0 <= Self.runBreakGap } ?? false
            if !continuesRun {
                current.runStartedAt = now
            }
            current.lastOutputAt = now
        }
    }

    /// Registra una tecla o texto enviado a la PTY desde el Mac o el móvil.
    func noteLocalInput(now: TimeInterval = Date().timeIntervalSince1970) {
        state.withLock { $0.lastLocalInputAt = now }
    }

    /// Registra un cambio de tamaño de la superficie.
    func noteResize(now: TimeInterval = Date().timeIntervalSince1970) {
        state.withLock { $0.lastResizeAt = now }
    }

    func snapshot() -> Snapshot {
        state.withLock { Snapshot(lastOutputAt: $0.lastOutputAt, runStartedAt: $0.runStartedAt) }
    }
}
