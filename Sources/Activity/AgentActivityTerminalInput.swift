import Foundation

/// Pruebas de una ventana de terminal tal y como salen del hilo principal hacia el monitor.
struct AgentActivityTerminalInput: Equatable, Sendable {
    /// Sesión tmux local que la sonda debe consultar para esta ventana.
    struct TmuxTarget: Hashable, Sendable {
        let socketName: String
        let sessionName: String

        init(socketName: String, sessionName: String) {
            self.socketName = socketName
            self.sessionName = sessionName
        }
    }

    let workspaceID: UUID
    let panelID: UUID
    let tmux: TmuxTarget?
    let evidence: AgentActivityEvidence

    init(workspaceID: UUID, panelID: UUID, tmux: TmuxTarget?, evidence: AgentActivityEvidence) {
        self.workspaceID = workspaceID
        self.panelID = panelID
        self.tmux = tmux
        self.evidence = evidence
    }
}
