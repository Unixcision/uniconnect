import SwiftUI

/// Indicador ligero de actividad de IA para la fila de un espacio de la barra lateral.
///
/// Ruedecita mientras la IA trabaja, mano ámbar cuando espera respuesta, nada en el
/// resto de estados. Recibe un valor precomputado: no observa ningún store.
struct SidebarAgentActivityIndicator: View, Equatable {
    let state: AgentActivity.State
    let fontSize: CGFloat

    /// Ámbar de la espera; el mismo tono en claro y oscuro para que se reconozca.
    static let waitingColor = Color(red: 1.0, green: 0.62, blue: 0.04)

    var body: some View {
        switch state {
        case .working:
            ProgressView()
                .controlSize(.mini)
                .frame(width: fontSize + 3, height: fontSize + 3)
                .safeHelp(Self.workingLabel)
                .accessibilityLabel(Self.workingLabel)
        case .waiting:
            Image(systemName: "hand.raised.fill")
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundColor(Self.waitingColor)
                .safeHelp(Self.waitingLabel)
                .accessibilityLabel(Self.waitingLabel)
        case .idle, .unknown:
            EmptyView()
        }
    }

    static var workingLabel: String {
        String(localized: "uniconnect.activity.working", defaultValue: "La IA está trabajando")
    }

    static var waitingLabel: String {
        String(localized: "uniconnect.activity.waiting", defaultValue: "La IA espera tu respuesta")
    }
}
