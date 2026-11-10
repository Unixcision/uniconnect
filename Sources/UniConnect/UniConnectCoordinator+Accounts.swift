import AppKit
import Foundation

/// «Cuentas de IA» (`accounts-v1`): the desktop window and `mobile.accounts.list` share one reading.
extension UniConnectCoordinator {
    /// Receives the reader from the executable composition root.
    func configureAccounts(reader: UniConnectAccountsReader) {
        accountsReader = reader
    }

    /// Opens (or brings forward) the «Cuentas de IA» window.
    func showAccountsWindow() {
        if accountsWindowController == nil {
            let model = UniConnectAccountsModel(
                load: { [weak self] in await self?.accountsSnapshot() },
                codexReset: { [weak self] account in await self?.confirmAndSpendCodexReset(account) ?? false }
            )
            accountsWindowController = UniConnectAccountsWindowController(model: model)
        }
        accountsWindowController?.show()
    }

    /// Reads every open window's agent account now; `nil` when the reader is not configured.
    func accountsSnapshot() async -> UniConnectAccountsSnapshot? {
        guard let reader = accountsReader else { return nil }
        return await reader.read(accountsInput())
    }

    /// Why a Codex reset could not be spent (`accounts-v1` §5 errors).
    enum CodexResetError: Error {
        case notFound
        case unavailable(String)
    }

    /// Spends one free Codex reset of `accountKey` on `hostKey` (`accounts-v1` §5), without asking.
    ///
    /// Reads the accounts first to pick a live window of that account on that host. Callers confirm
    /// with the user before calling (the desktop with an alert, the phone with its own dialog).
    func spendCodexReset(
        accountKey: String,
        hostKey: String,
        idempotencyKey: String
    ) async -> Result<UniConnectAccountsReader.CodexResetResult, CodexResetError> {
        guard let reader = accountsReader else { return .failure(.unavailable("sin_lector")) }
        let input = accountsInput()
        let snapshot = await reader.read(input)
        guard let target = snapshot.windows.first(where: { window in
            window.state == .ok && window.hostKey == hostKey && window.agent?.provider == "codex"
                && window.account?.email.map({ UniConnectAccountsSnapshot.accountKey(provider: "codex", email: $0) }) == accountKey
        }),
              let workspace = input.workspaces.first(where: { $0.id == target.workspaceID }),
              let window = workspace.windows.first(where: { $0.id == target.terminalID }) else {
            return .failure(.notFound)
        }
        switch await reader.codexReset(workspace: workspace, window: window, idempotencyKey: idempotencyKey) {
        case .success(let result): return .success(result)
        case .failure(let failure): return .failure(.unavailable(failure.code))
        }
    }

    /// Asks before spending a free Codex reset from the desktop window, then says what happened.
    ///
    /// - Returns: Whether a reset was attempted (so the window reads the accounts again).
    func confirmAndSpendCodexReset(_ account: UniConnectAccountsSnapshot.AccountSummary) async -> Bool {
        guard let credits = account.usage?.resetCredits, credits.available > 0,
              let hostKey = account.usage?.hostKey else { return false }
        let confirm = NSAlert()
        confirm.alertStyle = .warning
        let titleFormat = String(
            localized: "uniconnect.accounts.reset.confirmTitle",
            defaultValue: "¿Gastar 1 de %1$lld reseteos gratis de %2$@?"
        )
        confirm.messageText = String.localizedStringWithFormat(titleFormat, Int64(credits.available), account.email)
        confirm.informativeText = String(
            localized: "uniconnect.accounts.reset.confirmBody",
            defaultValue: "Los límites de Codex de esta cuenta vuelven a 0 %. No se puede deshacer."
        )
        confirm.addButton(withTitle: String(localized: "uniconnect.accounts.reset.confirmButton", defaultValue: "Gastar reseteo"))
        confirm.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancelar"))
        guard confirm.runModal() == .alertFirstButtonReturn else { return false }
        let key = UUID().uuidString.lowercased()
        let result = await spendCodexReset(accountKey: account.key, hostKey: hostKey, idempotencyKey: key)
        let done = NSAlert()
        switch result {
        case .success(let reset):
            done.alertStyle = reset.outcome == "reset" ? .informational : .warning
            done.messageText = Self.codexResetMessage(outcome: reset.outcome, email: account.email)
        case .failure(.notFound):
            done.alertStyle = .warning
            done.messageText = String(
                localized: "uniconnect.accounts.reset.notFound",
                defaultValue: "No hay ninguna ventana de esa cuenta abierta en ese equipo."
            )
        case .failure(.unavailable):
            done.alertStyle = .warning
            done.messageText = String(
                localized: "uniconnect.accounts.reset.unavailable",
                defaultValue: "No se pudo hablar con ese Codex. No se ha gastado ningún reseteo."
            )
        }
        done.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        done.runModal()
        return true
    }

    /// The message for each `outcome` of `accounts-v1` §5.
    static func codexResetMessage(outcome: String, email: String) -> String {
        switch outcome {
        case "reset":
            let format = String(localized: "uniconnect.accounts.reset.done", defaultValue: "Hecho: %@ vuelve a empezar.")
            return String(format: format, email)
        case "nothingToReset":
            return String(
                localized: "uniconnect.accounts.reset.nothing",
                defaultValue: "No había nada que resetear: no se ha gastado ninguno."
            )
        case "noCredit":
            return String(localized: "uniconnect.accounts.reset.noCredit", defaultValue: "Esta cuenta ya no tiene reseteos gratis.")
        default:
            return String(localized: "uniconnect.accounts.reset.already", defaultValue: "Ese reseteo ya se había aplicado.")
        }
    }

    /// The open workspaces and windows, as the reader's immutable input.
    func accountsInput() -> UniConnectAccountsInput {
        let localLabel = String(localized: "uniconnect.accounts.host.thisMac", defaultValue: "Este Mac")
        let unnamed = String(localized: "uniconnect.windowDetails.unnamedWindow", defaultValue: "Ventana")
        var workspaces: [UniConnectAccountsInput.Workspace] = []
        for workspace in allTabManagers().flatMap(\.tabs) {
            guard let profile = workspace.uniConnectProfile else { continue }
            let isSSH = profile.isSSH
            var hostKey = "local"
            var hostLabel = localLabel
            var credentialID: UUID?
            if isSSH {
                if let id = profile.credentialId,
                   let target = UniConnectVault.shared.credentialRecord(for: id)?.effectiveTarget {
                    credentialID = id
                    hostLabel = UniConnectWindowDetailsResolver.hostLabel(user: target.user, hostname: target.host, port: target.port)
                } else {
                    hostLabel = UniConnectWindowDetailsResolver.normalizedHostLabel(profile.hostLabel ?? workspace.title)
                }
                hostKey = "ssh:" + hostLabel
            }
            let windows = workspace.uniConnectOrderedTerminalPanelIds().compactMap { panelID -> UniConnectAccountsInput.Window? in
                guard workspace.panels[panelID] is TerminalPanel else { return nil }
                let record = workspace.uniConnectLocalWindowsByPanelId[panelID]
                let remoteSession = workspace.uniConnectTmuxSessionsByPanelId[panelID]
                let name = workspace.panelCustomTitles[panelID]
                    ?? record?.visibleName
                    ?? workspace.panelTitles[panelID]
                    ?? remoteSession
                    ?? unnamed
                if isSSH {
                    return .init(id: panelID, name: name, tmuxSocket: remoteSession == nil ? nil : "default", tmuxSession: remoteSession)
                }
                return .init(id: panelID, name: name, tmuxSocket: record?.tmuxBinding?.socketName, tmuxSession: record?.tmuxBinding?.name)
            }
            workspaces.append(.init(
                id: workspace.id,
                name: workspace.customTitle ?? workspace.title,
                kind: isSSH ? .ssh : .local,
                credentialID: credentialID,
                hostKey: hostKey,
                hostLabel: hostLabel,
                windows: windows
            ))
        }
        return UniConnectAccountsInput(workspaces: workspaces)
    }
}
