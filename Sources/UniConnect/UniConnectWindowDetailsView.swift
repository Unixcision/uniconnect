import AppKit
import SwiftUI

/// The «Detalles» modal of one window: workspace, window, tmux and agent, with the resume command.
///
/// It opens at once with what is saved and a «Comprobando…» mark, and updates when the live
/// reading arrives; if that fails it says so and keeps showing what was saved.
struct UniConnectWindowDetailsView: View {
    let model: UniConnectWindowDetailsModel
    let onClose: () -> Void

    private var snapshot: UniConnectWindowDetailsSnapshot { model.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(localized: "uniconnect.windowDetails.title", defaultValue: "Detalles de la ventana"))
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                statusLine
            }
            ScrollView {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
                    row(String(localized: "uniconnect.windowDetails.row.workspace", defaultValue: "Espacio de trabajo"),
                        snapshot.workspaceName)
                    row(String(localized: "uniconnect.windowDetails.row.kind", defaultValue: "Tipo"), kindText)
                    row(String(localized: "uniconnect.windowDetails.row.window", defaultValue: "Ventana"),
                        snapshot.windowName)
                    Divider().gridCellColumns(2)
                    tmuxRows
                    Divider().gridCellColumns(2)
                    agentRows
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let resume = snapshot.agent?.resume {
                resumeBlock(resume)
            }
            HStack {
                Spacer()
                if let command = snapshot.agent?.resume?.command {
                    Button(String(localized: "uniconnect.windowDetails.copy", defaultValue: "Copiar orden")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                }
                Button(String(localized: "uniconnect.windowDetails.close", defaultValue: "Cerrar"), action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private var statusLine: some View {
        if model.checking {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(String(localized: "uniconnect.windowDetails.checking", defaultValue: "Comprobando…"))
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        } else if model.checkFailed {
            Text(String(
                localized: "uniconnect.windowDetails.checkFailed",
                defaultValue: "No se pudo comprobar el servidor; se muestra lo guardado"
            ))
            .font(.system(size: 11))
            .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var tmuxRows: some View {
        if let tmux = snapshot.tmux {
            row(String(localized: "uniconnect.windowDetails.row.tmuxSocket", defaultValue: "Socket tmux"),
                tmux.socket == "default"
                    ? String(localized: "uniconnect.windowDetails.tmuxSocket.default", defaultValue: "Servidor tmux por defecto")
                    : tmux.socket)
            row(String(localized: "uniconnect.windowDetails.row.tmuxSession", defaultValue: "Sesión tmux"),
                tmux.session, monospaced: true)
            row(String(localized: "uniconnect.windowDetails.row.tmuxID", defaultValue: "ID tmux"), tmuxIDText(tmux),
                monospaced: tmux.live)
        } else {
            row(String(localized: "uniconnect.windowDetails.row.tmuxSession", defaultValue: "Sesión tmux"),
                String(localized: "uniconnect.windowDetails.tmux.none", defaultValue: "Sin tmux (ventana antigua)"))
        }
    }

    @ViewBuilder
    private var agentRows: some View {
        row(String(localized: "uniconnect.windowDetails.row.agent", defaultValue: "IA"), agentText)
        if let agent = snapshot.agent {
            row(String(localized: "uniconnect.windowDetails.row.state", defaultValue: "Estado"), stateText(agent.state))
            row(String(localized: "uniconnect.windowDetails.row.conversation", defaultValue: "ID de conversación"),
                agent.sessionID ?? "—", monospaced: agent.sessionID != nil)
            row(String(localized: "uniconnect.windowDetails.row.folder", defaultValue: "Carpeta"),
                agent.workingDirectory ?? "—", monospaced: agent.workingDirectory != nil)
            if snapshot.kind == .ssh {
                row(String(localized: "uniconnect.windowDetails.row.asRoot", defaultValue: "Como root"),
                    agent.asRoot
                        ? String(localized: "uniconnect.windowDetails.yes", defaultValue: "Sí")
                        : String(localized: "uniconnect.windowDetails.no", defaultValue: "No"))
            }
            row(String(localized: "uniconnect.windowDetails.row.source", defaultValue: "Origen del dato"),
                sourceText(agent.source))
        }
    }

    private func resumeBlock(_ resume: UniConnectWindowDetailsSnapshot.Resume) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "uniconnect.windowDetails.row.resume", defaultValue: "Orden para reanudarla"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(resume.command)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
            if !resume.noPromptVerified {
                Text(String(
                    localized: "uniconnect.windowDetails.notVerified",
                    defaultValue: "Sin modo sin preguntas verificado para esta IA"
                ))
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            }
        }
    }

    private func row(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        GridRow {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var kindText: String {
        switch snapshot.kind {
        case .local:
            return String(localized: "uniconnect.windowDetails.kind.local", defaultValue: "Local")
        case .ssh:
            guard let label = snapshot.hostLabel else {
                return String(localized: "uniconnect.windowDetails.kind.vpsUnknown", defaultValue: "VPS")
            }
            return String(
                format: String(localized: "uniconnect.windowDetails.kind.vps", defaultValue: "VPS (%@)"),
                label
            )
        }
    }

    private func tmuxIDText(_ tmux: UniConnectWindowDetailsSnapshot.Tmux) -> String {
        guard tmux.live, let sessionID = tmux.sessionID else {
            return String(localized: "uniconnect.windowDetails.tmuxID.notRunning", defaultValue: "No está en marcha ahora")
        }
        return [sessionID, tmux.paneID].compactMap { $0 }.joined(separator: " · ")
    }

    private var agentText: String {
        if let agent = snapshot.agent {
            if agent.sessionID == nil {
                return String(
                    localized: "uniconnect.windowDetails.agent.noID",
                    defaultValue: "IA detectada, sin identificador todavía"
                ) + " (\(agent.displayName))"
            }
            return agent.displayName
        }
        switch snapshot.reason {
        case "identidad_ambigua":
            return String(localized: "uniconnect.windowDetails.agent.ambiguous", defaultValue: "Hay más de una IA en esta ventana")
        case "host_inaccesible":
            return String(localized: "uniconnect.windowDetails.agent.unreachable", defaultValue: "Sin IA guardada; el servidor no respondió")
        default:
            return String(localized: "uniconnect.windowDetails.agent.none", defaultValue: "Sin IA detectada")
        }
    }

    private func stateText(_ state: UniConnectWindowDetailsSnapshot.AgentState) -> String {
        switch state {
        case .active:
            return String(localized: "uniconnect.windowDetails.state.active", defaultValue: "En marcha")
        case .saved:
            return String(localized: "uniconnect.windowDetails.state.saved", defaultValue: "Guardada (no comprobada ahora)")
        case .interrupted:
            return String(localized: "uniconnect.windowDetails.state.interrupted", defaultValue: "Interrumpida: se reanudará al abrir")
        }
    }

    private func sourceText(_ source: String?) -> String {
        switch source {
        case "ficha":
            return String(localized: "uniconnect.windowDetails.source.ficha", defaultValue: "Ficha de sesión de Claude")
        case "rollout":
            return String(localized: "uniconnect.windowDetails.source.rollout", defaultValue: "Registro abierto de Codex")
        case "argv":
            return String(localized: "uniconnect.windowDetails.source.argv", defaultValue: "Línea de órdenes del proceso (puede estar desfasada)")
        case "hook":
            return String(localized: "uniconnect.windowDetails.source.hook", defaultValue: "Aviso del propio agente")
        case "manifiesto":
            return String(localized: "uniconnect.windowDetails.source.manifiesto", defaultValue: "Supervisor del servidor")
        case "registro":
            return String(localized: "uniconnect.windowDetails.source.registro", defaultValue: "Guardado en UniConnect")
        default:
            return "—"
        }
    }
}
