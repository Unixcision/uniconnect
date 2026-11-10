import Foundation

/// Costura entre el ciclo de actividad y el host (espacios, paneles, superficies).
///
/// Todo ocurre en el hilo principal porque el estado de los espacios vive ahí; el
/// ``AgentActivityCoordinator`` la usa para recoger pruebas y publicar resultados. Lo que se
/// hace aquí es solo copiar: decidir (incluido analizar el texto de pantalla) va fuera.
@MainActor
protocol AgentActivityHostReading: AnyObject {
    /// Pruebas de todas las ventanas de terminal vivas, con `now` como epoch en segundos.
    func terminalInputs(now: TimeInterval) -> [AgentActivityTerminalInput]
    /// El texto visible de esas ventanas, leído una vez por ciclo y de una sola pasada.
    ///
    /// Solo lo copia de la superficie: el análisis (``AgentActivityScreenSignal``) lo hace el
    /// monitor fuera del hilo principal, y el texto no sale de ese ciclo. Una ventana sin
    /// superficie viva no aparece en el resultado.
    func screenTexts(panelIDs: Set<UUID>) -> [UUID: String]
    /// Publica el resultado por espacio (barra lateral y snapshot móvil).
    func apply(activitiesByWorkspace: [UUID: [UUID: AgentActivity]])
}
