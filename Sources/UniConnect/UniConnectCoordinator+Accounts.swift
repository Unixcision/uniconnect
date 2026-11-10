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
            let model = UniConnectAccountsModel { [weak self] in
                await self?.accountsSnapshot()
            }
            accountsWindowController = UniConnectAccountsWindowController(model: model)
        }
        accountsWindowController?.show()
    }

    /// Reads every open window's agent account now; `nil` when the reader is not configured.
    func accountsSnapshot() async -> UniConnectAccountsSnapshot? {
        guard let reader = accountsReader else { return nil }
        return await reader.read(accountsInput())
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
