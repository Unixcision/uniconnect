import Foundation

/// Costura entre el ciclo de actividad y el host (espacios, paneles, superficies).
///
/// Todo ocurre en el hilo principal porque el estado de los espacios vive ahí; el
/// ``AgentActivityCoordinator`` la usa para recoger pruebas y publicar resultados.
@MainActor
protocol AgentActivityHostReading: AnyObject {
    /// Pruebas de todas las ventanas de terminal vivas, con `now` como epoch en segundos.
    func terminalInputs(now: TimeInterval) -> [AgentActivityTerminalInput]
    /// Veredicto de pantalla de una ventana: hay una pregunta de permiso visible. El texto
    /// capturado no sale del host; sin superficie viva devuelve `false`.
    func screenShowsPermissionPrompt(panelID: UUID) -> Bool
    /// Publica el resultado por espacio (barra lateral y snapshot móvil).
    func apply(activitiesByWorkspace: [UUID: [UUID: AgentActivity]])
}
