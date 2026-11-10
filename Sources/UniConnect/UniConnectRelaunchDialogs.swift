import AppKit
import CMUXAgentLaunch
import Foundation

/// The desktop's confirmation and report for Relanzar IA and Actualizar Claude.
///
/// What is shown before confirming is what the plan says will happen: which windows, what each one
/// will lose or keep (work in progress, a pending permission, monitors, a draft), what it will cost
/// («Reabrir no gasta; el mensaje a N IAs releerá ~X tokens») and, for an update, the model and
/// effort to reopen with. Nothing here decides anything: it only asks and tells.
@MainActor
struct UniConnectRelaunchDialogs {
    /// A model offered for `agent.update`, by the alias Claude accepts.
    private struct ModelChoice {
        let title: String
        let alias: String?
    }

    private static let models: [ModelChoice] = [
        .init(title: String(localized: "uniconnect.relaunch.update.model.same", defaultValue: "Igual que estaba"), alias: nil),
        .init(title: "Fable 5.2", alias: "fable[1m]"),
        .init(title: "Opus 5.5", alias: "opus[1m]"),
        .init(title: "Sonnet 5.5", alias: "sonnet[1m]"),
        .init(title: "Haiku 5.5", alias: "haiku"),
    ]

    /// Shows the plan and waits for a yes.
    ///
    /// - Parameter preview: The plan.
    /// - Returns: The options to run with (the chosen model and effort for an update), or `nil`
    ///   when the person cancelled.
    func confirm(_ preview: UniConnectRelaunchCoordinator.Preview) -> RelaunchUpdateOptions? {
        let alert = NSAlert()
        alert.alertStyle = .warning
        let count = preview.targets.count
        let update = preview.verb == .agentUpdate
        alert.messageText = update
            ? String(localized: "uniconnect.relaunch.update.confirm.title", defaultValue: "¿Actualizar Claude en \(count) ventanas?")
            : String(localized: "uniconnect.relaunch.confirm.title", defaultValue: "¿Relanzar \(count) ventanas?")

        var lines = preview.targets.prefix(12).map { target in
            ([target.label] + details(of: target.notes)).joined(separator: " — ")
        }
        if preview.targets.count > 12 { lines.append("…") }
        var detail = lines.map { "• " + $0 }.joined(separator: "\n")
        if preview.reportsCost {
            detail += "\n\n" + costLine(preview)
        }
        if !preview.exclusions.isEmpty {
            detail += "\n\n" + String(
                localized: "uniconnect.relaunch.confirm.excluded",
                defaultValue: "Se quedan fuera \(preview.exclusions.count), intactas."
            )
            let shown = preview.exclusions.prefix(8).map { "• \($0.label) — \(causeText($0.cause))" }
            detail += "\n" + shown.joined(separator: "\n")
            if preview.exclusions.count > 8 { detail += "\n…" }
        }
        alert.informativeText = detail

        var modelPopUp: NSPopUpButton?
        var effortPopUp: NSPopUpButton?
        if update {
            let model = NSPopUpButton(frame: .zero, pullsDown: false)
            model.addItems(withTitles: Self.models.map(\.title))
            let effort = NSPopUpButton(frame: .zero, pullsDown: false)
            effort.addItem(withTitle: String(localized: "uniconnect.relaunch.update.effort.same", defaultValue: "Igual"))
            effort.addItems(withTitles: RelaunchEffort.allCases.map(\.rawValue))
            let grid = NSGridView(views: [
                [NSTextField(labelWithString: String(localized: "uniconnect.relaunch.update.model", defaultValue: "Modelo")), model],
                [NSTextField(labelWithString: String(localized: "uniconnect.relaunch.update.effort", defaultValue: "Effort")), effort],
            ])
            grid.rowSpacing = 6
            grid.columnSpacing = 8
            grid.frame = NSRect(x: 0, y: 0, width: 300, height: 56)
            alert.accessoryView = grid
            modelPopUp = model
            effortPopUp = effort
        }

        alert.addButton(withTitle: update
            ? String(localized: "uniconnect.relaunch.update.confirm.go", defaultValue: "Actualizar")
            : String(localized: "uniconnect.relaunch.confirm.go", defaultValue: "Relanzar"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        guard update else { return .unchanged }
        let alias = modelPopUp.map { Self.models[max(0, $0.indexOfSelectedItem)].alias } ?? nil
        let effortIndex = effortPopUp?.indexOfSelectedItem ?? 0
        let effort = effortIndex > 0 ? RelaunchEffort.allCases[effortIndex - 1].rawValue : nil
        return (try? RelaunchUpdateOptions(model: alias, effort: effort)) ?? .unchanged
    }

    /// Why an empty plan has nothing to do, in one sentence.
    func emptyPlanMessage(_ preview: UniConnectRelaunchCoordinator.Preview) -> String {
        guard !preview.exclusions.isEmpty else {
            return String(localized: "uniconnect.relaunch.error.nothingToDo", defaultValue: "No hay ninguna IA que relanzar aquí.")
        }
        let reasons = preview.exclusions.prefix(8).map { "• \($0.label) — \(causeText($0.cause))" }.joined(separator: "\n")
        return String(
            localized: "uniconnect.relaunch.error.allExcluded",
            defaultValue: "Ninguna de estas ventanas se puede relanzar ahora. Se quedan como están."
        ) + "\n\n" + reasons
    }

    /// Tells how each window ended, without hiding the ones that need somebody.
    func report(_ operation: RelaunchOperation, labels: [RelaunchTargetKey: String]) {
        let verified = operation.results.filter { $0.state == .verified }.count
        let failedUpdates = operation.updates.filter { $0.state == .failed }
        let problems = operation.results.filter { $0.state != .verified }
        guard !problems.isEmpty || !failedUpdates.isEmpty else { return }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = operation.verb == .agentUpdate
            ? String(localized: "uniconnect.relaunch.update.done.title", defaultValue: "Actualizadas \(verified) de \(operation.results.count)")
            : String(localized: "uniconnect.relaunch.done.title", defaultValue: "Relanzadas \(verified) de \(operation.results.count)")
        var detail: [String] = []
        for update in failedUpdates {
            detail.append(String(
                localized: "uniconnect.relaunch.update.done.failedHost",
                defaultValue: "No se pudo actualizar Claude en \(update.host); sus ventanas no se han tocado."
            ))
        }
        for result in problems.prefix(12) {
            let label = labels[result.key] ?? result.key.text
            let state = stateText(result.state)
            let cause = result.cause.map { " — " + causeText($0) } ?? ""
            detail.append("• \(label): \(state)\(cause)")
        }
        if problems.count > 12 { detail.append("…") }
        alert.informativeText = detail.joined(separator: "\n")
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.runModal()
    }

    /// The notes of a target as short phrases.
    private func details(of notes: RelaunchTargetNotes) -> [String] {
        var parts: [String] = []
        switch notes.warning {
        case .backgroundTasks?:
            parts.append(String(localized: "uniconnect.relaunch.note.working", defaultValue: "trabajando o con tareas: se cortan"))
        case .permissions?:
            parts.append(String(localized: "uniconnect.relaunch.note.permission", defaultValue: "esperaba un permiso: se descarta la llamada"))
        default:
            break
        }
        if let background = notes.background, background > 0 {
            parts.append(String(localized: "uniconnect.relaunch.note.background", defaultValue: "\(background) monitores se guardan y se le devuelven"))
        }
        if notes.draft == true {
            parts.append(String(localized: "uniconnect.relaunch.note.draft", defaultValue: "su borrador se conserva sin enviar"))
        }
        if let version = notes.version, let installed = notes.installed {
            parts.append(String(localized: "uniconnect.relaunch.note.version", defaultValue: "ahora Claude \(version), instalada \(installed)"))
        }
        if !notes.droppedOptions.isEmpty {
            let names = notes.droppedOptions.joined(separator: ", ")
            parts.append(String(localized: "uniconnect.relaunch.note.dropped", defaultValue: "vuelve sin \(names)"))
        }
        return parts
    }

    /// «Reabrir no gasta; el mensaje a N IAs releerá ~X tokens».
    private func costLine(_ preview: UniConnectRelaunchCoordinator.Preview) -> String {
        let messaged = preview.targets.filter { $0.notes.message == true }.count
        guard messaged > 0 else {
            return String(localized: "uniconnect.relaunch.cost.none", defaultValue: "Reabrir no gasta, y no se escribirá nada en ninguna.")
        }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "es_ES")
        formatter.numberStyle = .decimal
        let tokens = formatter.string(from: NSNumber(value: preview.estimatedTokens)) ?? String(preview.estimatedTokens)
        return String(
            localized: "uniconnect.relaunch.cost.message",
            defaultValue: "Reabrir no gasta; el mensaje a \(messaged) IAs releerá ~\(tokens) tokens."
        )
    }

    /// A target state in words.
    private func stateText(_ state: RelaunchTargetState) -> String {
        switch state {
        case .verified: String(localized: "uniconnect.relaunch.state.verificado", defaultValue: "verificada")
        case .needsUser: String(localized: "uniconnect.relaunch.state.necesita_usuario", defaultValue: "te necesita")
        case .skipped: String(localized: "uniconnect.relaunch.state.omitido", defaultValue: "sin tocar")
        case .failed: String(localized: "uniconnect.relaunch.state.fallido", defaultValue: "sin confirmar, revísala")
        case .planned: String(localized: "uniconnect.relaunch.state.planificado", defaultValue: "pendiente")
        case .closing: String(localized: "uniconnect.relaunch.state.cerrando", defaultValue: "cerrando")
        case .reopening: String(localized: "uniconnect.relaunch.state.reabriendo", defaultValue: "reabriendo")
        case .reattaching: String(localized: "uniconnect.relaunch.state.reenganchando", defaultValue: "reenganchando")
        case .delivering: String(localized: "uniconnect.relaunch.state.entregando", defaultValue: "entregando")
        }
    }

    /// A cause in words, the same texts the phone and Linux show (`causes.json`).
    func causeText(_ cause: RelaunchCause) -> String {
        switch cause {
        case .ambiguousIdentity: String(localized: "uniconnect.relaunch.cause.identidad_ambigua", defaultValue: "No se pudo determinar con certeza qué conversación es. No se cierra nada.")
        case .unknownDialog: String(localized: "uniconnect.relaunch.cause.dialogo_desconocido", defaultValue: "La pantalla mostraba algo que no se reconoce. No se responde a ciegas.")
        case .folderTrust: String(localized: "uniconnect.relaunch.cause.confianza_carpeta", defaultValue: "El agente pidió confirmar la carpeta. Lo tiene que contestar una persona.")
        case .permissions: String(localized: "uniconnect.relaunch.cause.permisos", defaultValue: "El agente esperaba una respuesta de permisos. Relanzar la descarta: la conversación vuelve, la llamada pendiente no.")
        case .noAuthority: String(localized: "uniconnect.relaunch.cause.sin_autoridad", defaultValue: "Nadie tiene autoridad resoluble sobre este objetivo, o la tiene otro ejecutor.")
        case .notSent: String(localized: "uniconnect.relaunch.cause.no_enviado", defaultValue: "La app canceló el trabajo antes del despacho. No se relanzó; requiere un plan nuevo si todavía se desea.")
        case .generationChanged: String(localized: "uniconnect.relaunch.cause.generacion_cambiada", defaultValue: "El objetivo cambió entre el plan y la ejecución. Hace falta un plan nuevo.")
        case .hostUnreachable: String(localized: "uniconnect.relaunch.cause.host_inaccesible", defaultValue: "El equipo no respondió.")
        case .duplicate: String(localized: "uniconnect.relaunch.cause.duplicado", defaultValue: "El mismo objetivo ya lo ejecuta otro; aquí no se repite.")
        case .unsupported: String(localized: "uniconnect.relaunch.cause.no_soportado", defaultValue: "El equipo no anuncia relaunch.v1.")
        case .noAgent: String(localized: "uniconnect.relaunch.cause.sin_ia", defaultValue: "La ventana no tiene ninguna IA en marcha. No hay nada que relanzar.")
        case .backgroundTasks: String(localized: "uniconnect.relaunch.cause.tareas_de_fondo", defaultValue: "El agente tiene tareas o monitores en marcha. Relanzar los detiene.")
        case .providerUnsupported: String(localized: "uniconnect.relaunch.cause.proveedor_no_soportado", defaultValue: "Esta IA todavía no se sabe relanzar en este equipo.")
        case .noTmux: String(localized: "uniconnect.relaunch.cause.sin_tmux", defaultValue: "La ventana no está dentro de una sesión tmux, así que no hay sesión que conservar.")
        case .noCredential: String(localized: "uniconnect.relaunch.cause.sin_credencial", defaultValue: "La caja SSH no tiene su credencial disponible ahora mismo.")
        case .destinationNotLinux: String(localized: "uniconnect.relaunch.cause.destino_no_linux", defaultValue: "El servidor no deja inspeccionar sus procesos (sin /proc o pidfd).")
        case .missingFolder: String(localized: "uniconnect.relaunch.cause.carpeta_inexistente", defaultValue: "La carpeta de la ventana ya no existe.")
        case .missingBinary: String(localized: "uniconnect.relaunch.cause.binario_no_encontrado", defaultValue: "El programa de la IA no está instalado o no se puede ejecutar.")
        case .notPaused: String(localized: "uniconnect.relaunch.cause.sin_pausa", defaultValue: "Codex no está pausado por límite de uso: no hay nada que continuar.")
        case .sharedSession: String(localized: "uniconnect.relaunch.cause.sesion_compartida", defaultValue: "La sesión tmux tiene paneles o ventanas ajenos. No se mata para no llevárselos por delante.")
        case .notLoggedIn: String(localized: "uniconnect.relaunch.cause.sin_login", defaultValue: "Claude no tiene la sesión iniciada en ese equipo. Reabrirla la dejaría inservible; antes hay que hacer /login.")
        case .sharedConversation: String(localized: "uniconnect.relaunch.cause.conversacion_compartida", defaultValue: "Otra ventana tiene abierta la misma conversación. Reabrir volvería a la rama de la otra y esta perdería su hilo.")
        case .updateFailed: String(localized: "uniconnect.relaunch.cause.actualizacion_fallida", defaultValue: "No se pudo actualizar Claude en ese equipo. No se ha cerrado nada.")
        }
    }
}
