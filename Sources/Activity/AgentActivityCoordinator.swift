import Foundation
import Observation

/// Orquesta el ciclo de actividad: recoge pruebas del host, pide al monitor que decida
/// y publica el resultado en los espacios cada ``interval``.
///
/// Se construye una sola vez en la raíz de composición (`AppDelegate`) y no tiene
/// estado de dominio propio: los espacios guardan la actividad publicada.
@MainActor
@Observable
final class AgentActivityCoordinator {
    /// Fecha de la última evaluación completada.
    private(set) var lastEvaluatedAt: Date?

    @ObservationIgnored private let host: any AgentActivityHostReading
    @ObservationIgnored private let monitor: AgentActivityMonitor
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private var loopTask: Task<Void, Never>?

    /// - Parameters:
    ///   - host: Costura con los espacios y las superficies.
    ///   - monitor: Servicio que decide la actividad fuera del hilo principal.
    ///   - clock: Reloj del ciclo; los tests inyectan uno virtual.
    ///   - interval: Separación entre evaluaciones (también coalesce las emisiones al móvil).
    init(
        host: any AgentActivityHostReading,
        monitor: AgentActivityMonitor = AgentActivityMonitor(),
        clock: any Clock<Duration> = ContinuousClock(),
        interval: Duration = .seconds(2)
    ) {
        self.host = host
        self.monitor = monitor
        self.clock = clock
        self.interval = interval
    }

    /// Arranca el ciclo periódico; es idempotente.
    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.evaluateOnce()
                // Retardo acotado y cancelable con reloj inyectado: el intervalo de sondeo
                // es el comportamiento deseado (tmux y la pantalla no avisan por sí solos).
                do {
                    try await self.clock.sleep(for: self.interval)
                } catch {
                    return
                }
            }
        }
    }

    /// Detiene el ciclo; las actividades ya publicadas se conservan.
    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// Una evaluación completa: recoger, decidir y publicar.
    func evaluateOnce() async {
        let now = Date().timeIntervalSince1970
        let inputs = host.terminalInputs(now: now)
        let host = self.host
        let result = inputs.isEmpty
            ? [:]
            : await monitor.evaluate(inputs: inputs, now: now) { panelID in
                host.visibleText(panelID: panelID)
            }
        host.apply(activitiesByWorkspace: result)
        lastEvaluatedAt = Date()
    }
}
