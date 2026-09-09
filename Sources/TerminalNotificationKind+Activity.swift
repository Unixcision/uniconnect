import Foundation

extension TerminalNotificationKind {
    /// Kind final de un aviso: el explícito del hook o, si no lo hay, el estado de
    /// actividad de la ventana en ese instante (`waiting` → `attention`, `idle` →
    /// `finished`, `working`/`unknown` → `info`).
    static func derived(
        explicit: TerminalNotificationKind?,
        activityState: AgentActivity.State?
    ) -> TerminalNotificationKind {
        if let explicit { return explicit }
        switch activityState {
        case .waiting?: return .attention
        case .idle?: return .finished
        case .working?, .unknown?, nil: return .info
        }
    }
}
