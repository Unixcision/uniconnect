import Foundation

/// The literal rows of the «Detalles» modal for one snapshot, as `contracts/window-details-v1`
/// fixes them (`LEEME.md` and `filas.json`); Mac, Linux and Android show the same text.
///
/// The view only lays these out, so the texts are tested without drawing anything.
struct UniConnectWindowDetailsRows: Equatable {
    /// One label and its value.
    struct Row: Equatable {
        let label: String
        let value: String
    }

    /// The notice above the rows when the live check failed (`host_inaccesible`), or `nil`.
    let notice: String?
    /// Rows 1 to 12, in order; the agent rows only when there is an agent.
    let rows: [Row]
    /// The «Orden para reanudarla» label.
    let resumeLabel: String
    /// The resume command (row 13), or `nil` without one.
    let resumeCommand: String?
    /// The note under the command when the provider's no-prompt mode is not verified, or `nil`.
    let resumeNote: String?

    /// Every row, the resume command included, as `filas.json` lists them.
    var allRows: [Row] {
        rows + (resumeCommand.map { [Row(label: resumeLabel, value: $0)] } ?? [])
    }

    init(snapshot: UniConnectWindowDetailsSnapshot) {
        let empty = "—"
        func text(_ value: String?) -> String {
            guard let value, !value.isEmpty else { return empty }
            return value
        }
        let unreachable = snapshot.reason == "host_inaccesible"
        if unreachable {
            notice = snapshot.kind == .ssh
                ? String(
                    localized: "uniconnect.windowDetails.checkFailed",
                    defaultValue: "No se pudo comprobar el servidor; se muestra lo guardado"
                )
                : String(
                    localized: "uniconnect.windowDetails.checkFailedLocal",
                    defaultValue: "No se pudo comprobar tmux en este equipo; se muestra lo guardado"
                )
        } else {
            notice = nil
        }

        var rows: [Row] = []
        rows.append(Row(
            label: String(localized: "uniconnect.windowDetails.row.workspace", defaultValue: "Espacio de trabajo"),
            value: text(snapshot.workspaceName)
        ))
        let kind: String
        switch snapshot.kind {
        case .local:
            kind = String(localized: "uniconnect.windowDetails.kind.local", defaultValue: "Local")
        case .ssh:
            if let label = snapshot.hostLabel, !label.isEmpty {
                kind = String(
                    format: String(localized: "uniconnect.windowDetails.kind.vps", defaultValue: "VPS (%@)"),
                    label
                )
            } else {
                kind = String(localized: "uniconnect.windowDetails.kind.vpsUnknown", defaultValue: "VPS")
            }
        }
        rows.append(Row(label: String(localized: "uniconnect.windowDetails.row.kind", defaultValue: "Tipo"), value: kind))
        rows.append(Row(
            label: String(localized: "uniconnect.windowDetails.row.window", defaultValue: "Ventana"),
            value: text(snapshot.windowName)
        ))

        let sessionLabel = String(localized: "uniconnect.windowDetails.row.tmuxSession", defaultValue: "Sesión tmux")
        if let tmux = snapshot.tmux {
            rows.append(Row(
                label: String(localized: "uniconnect.windowDetails.row.tmuxSocket", defaultValue: "Socket tmux"),
                value: tmux.socket == "default"
                    ? String(localized: "uniconnect.windowDetails.tmuxSocket.default", defaultValue: "Servidor tmux por defecto")
                    : text(tmux.socket)
            ))
            rows.append(Row(label: sessionLabel, value: text(tmux.session)))
            let identity: String
            if tmux.live, let sessionID = tmux.sessionID {
                identity = [sessionID, tmux.paneID].compactMap { $0 }.joined(separator: " · ")
            } else if unreachable {
                identity = String(localized: "uniconnect.windowDetails.tmuxID.unchecked", defaultValue: "Sin comprobar")
            } else {
                identity = String(localized: "uniconnect.windowDetails.tmuxID.notRunning", defaultValue: "No está en marcha ahora")
            }
            rows.append(Row(
                label: String(localized: "uniconnect.windowDetails.row.tmuxID", defaultValue: "ID tmux"),
                value: identity
            ))
        } else {
            rows.append(Row(
                label: sessionLabel,
                value: String(
                    localized: "uniconnect.windowDetails.tmux.none",
                    defaultValue: "Sin tmux: terminal directa sin sesión recuperable"
                )
            ))
        }

        let agentValue: String
        if snapshot.reason == "identidad_ambigua" {
            agentValue = String(localized: "uniconnect.windowDetails.agent.ambiguous", defaultValue: "Hay más de una IA en esta ventana")
        } else if let agent = snapshot.agent {
            if agent.sessionID == nil, agent.state == .active {
                agentValue = String(
                    format: String(
                        localized: "uniconnect.windowDetails.agent.liveNoID",
                        defaultValue: "%@: IA detectada, sin identificador todavía"
                    ),
                    agent.displayName
                )
            } else if agent.sessionID == nil {
                agentValue = String(
                    format: String(
                        localized: "uniconnect.windowDetails.agent.savedNoID",
                        defaultValue: "%@: sin identificador guardado"
                    ),
                    agent.displayName
                )
            } else {
                agentValue = text(agent.displayName)
            }
        } else if unreachable {
            agentValue = String(localized: "uniconnect.windowDetails.agent.unreachable", defaultValue: "Sin IA guardada")
        } else {
            agentValue = String(localized: "uniconnect.windowDetails.agent.none", defaultValue: "Sin IA detectada")
        }
        rows.append(Row(label: String(localized: "uniconnect.windowDetails.row.agent", defaultValue: "IA"), value: agentValue))

        if let agent = snapshot.agent {
            let state: String
            switch agent.state {
            case .active:
                state = String(localized: "uniconnect.windowDetails.state.active", defaultValue: "En marcha")
            case .interrupted:
                state = String(localized: "uniconnect.windowDetails.state.interrupted", defaultValue: "Interrumpida: se reanudará al abrir")
            case .saved:
                state = snapshot.reason == "sin_ia"
                    ? String(
                        localized: "uniconnect.windowDetails.state.savedAtShell",
                        defaultValue: "Guardada; ahora no hay ninguna IA en marcha"
                    )
                    : String(localized: "uniconnect.windowDetails.state.saved", defaultValue: "Guardada (no comprobada ahora)")
            }
            rows.append(Row(label: String(localized: "uniconnect.windowDetails.row.state", defaultValue: "Estado"), value: state))
            rows.append(Row(
                label: String(localized: "uniconnect.windowDetails.row.conversation", defaultValue: "ID de conversación"),
                value: text(agent.sessionID)
            ))
            rows.append(Row(
                label: String(localized: "uniconnect.windowDetails.row.folder", defaultValue: "Carpeta"),
                value: text(agent.workingDirectory)
            ))
            if snapshot.kind == .ssh {
                rows.append(Row(
                    label: String(localized: "uniconnect.windowDetails.row.asRoot", defaultValue: "Como root"),
                    value: agent.asRoot
                        ? String(localized: "uniconnect.windowDetails.yes", defaultValue: "Sí")
                        : String(localized: "uniconnect.windowDetails.no", defaultValue: "No")
                ))
            }
            rows.append(Row(
                label: String(localized: "uniconnect.windowDetails.row.source", defaultValue: "Origen del dato"),
                value: Self.sourceText(agent.source)
            ))
        }
        self.rows = rows
        resumeLabel = String(localized: "uniconnect.windowDetails.row.resume", defaultValue: "Orden para reanudarla")
        resumeCommand = snapshot.agent?.resume?.command
        if let resume = snapshot.agent?.resume, !resume.noPromptVerified {
            resumeNote = String(
                localized: "uniconnect.windowDetails.notVerified",
                defaultValue: "Sin modo sin preguntas verificado para esta IA"
            )
        } else {
            resumeNote = nil
        }
    }

    /// Where the agent's data came from, in words; an unknown source is shown as it is.
    private static func sourceText(_ source: String?) -> String {
        switch source {
        case "ficha"?:
            return String(localized: "uniconnect.windowDetails.source.ficha", defaultValue: "Ficha de sesión de Claude")
        case "rollout"?:
            return String(localized: "uniconnect.windowDetails.source.rollout", defaultValue: "Registro abierto de Codex")
        case "argv"?:
            return String(
                localized: "uniconnect.windowDetails.source.argv",
                defaultValue: "Línea de órdenes del proceso (puede estar desfasada)"
            )
        case "hook"?:
            return String(localized: "uniconnect.windowDetails.source.hook", defaultValue: "Aviso del propio agente")
        case "manifiesto"?:
            return String(localized: "uniconnect.windowDetails.source.manifiesto", defaultValue: "Supervisor del servidor")
        case "registro"?:
            return String(localized: "uniconnect.windowDetails.source.registro", defaultValue: "Guardado en UniConnect")
        case let other?:
            return other.isEmpty ? "—" : other
        case nil:
            return "—"
        }
    }
}
