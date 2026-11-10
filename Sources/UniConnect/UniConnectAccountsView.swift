import SwiftUI

/// The «Cuentas de IA» window (`accounts-v1` §4): which account every agent uses, and each
/// account's usage, read live.
struct UniConnectAccountsView: View {
    @Bindable var model: UniConnectAccountsModel
    let onAlwaysOnTopChange: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch model.tab {
            case .windows:
                windowsTab
            case .usage:
                providerBar
                UniConnectAccountsUsageView(
                    snapshot: model.snapshot,
                    accounts: model.visibleAccounts,
                    selectedKey: $model.selectedAccountKey,
                    resettingKey: model.resettingKey,
                    onShowWindows: { email in model.showWindows(ofEmail: email) },
                    onCodexReset: { account in model.spendCodexReset(account) }
                )
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.alwaysOnTop) { _, value in onAlwaysOnTopChange(value) }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "uniconnect.accounts.title", defaultValue: "Cuentas de IA"))
                    .font(.system(size: 20, weight: .bold))
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(verbatim: freshnessText(now: context.date))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer()
            Picker("", selection: $model.tab) {
                Text(String(localized: "uniconnect.accounts.tab.windows", defaultValue: "Ventanas"))
                    .tag(UniConnectAccountsModel.Tab.windows)
                Text(String(localized: "uniconnect.accounts.tab.usage", defaultValue: "Uso por cuenta"))
                    .tag(UniConnectAccountsModel.Tab.usage)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            Spacer()
            Toggle(isOn: $model.alwaysOnTop) {
                Text(String(localized: "uniconnect.accounts.alwaysOnTop", defaultValue: "Siempre delante"))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            Button {
                model.refresh()
            } label: {
                HStack(spacing: 6) {
                    if model.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(String(localized: "uniconnect.accounts.refresh", defaultValue: "Actualizar"))
                }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.isLoading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func freshnessText(now: Date) -> String {
        guard let snapshot = model.snapshot else {
            return String(localized: "uniconnect.accounts.reading", defaultValue: "Leyendo las cuentas…")
        }
        let format = String(localized: "uniconnect.accounts.readLive", defaultValue: "Leído en vivo %@ · se actualiza cada 15 s")
        return String(format: format, UniConnectAccountsUsageMath(now: now).age(of: snapshot.checkedAt))
    }

    // MARK: Windows tab

    private var windowsTab: some View {
        VStack(spacing: 0) {
            providerBar
            chipsBar
            controls
            ForEach(model.hostWarnings) { host in
                hostWarning(host)
            }
            if model.snapshot == nil {
                Spacer()
                ProgressView(String(localized: "uniconnect.accounts.reading", defaultValue: "Leyendo las cuentas…"))
                Spacer()
            } else if model.sections.isEmpty {
                Spacer()
                Text(String(localized: "uniconnect.accounts.empty", defaultValue: "No hay ventanas que coincidan."))
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                windowList
            }
        }
    }

    /// «Todas las IA · 56», «Claude Code · 44», «Codex · 8»…: only the agents in this reading.
    private var providerBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text(String(localized: "uniconnect.accounts.filter.agentLabel", defaultValue: "IA"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(model.providerChips) { chip in
                    let selected = model.providerFilter == chip.provider
                    Button {
                        model.providerFilter = chip.provider
                        if model.filter != .all { model.filter = .all }
                    } label: {
                        HStack(spacing: 6) {
                            Text(verbatim: chip.title).font(.system(size: 12, weight: .semibold))
                            Text(verbatim: "\(chip.count)")
                                .font(.system(size: 11, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(selected ? Color.white.opacity(0.9) : Color.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.primary.opacity(0.75) : Color.secondary.opacity(0.1)))
                        .foregroundStyle(selected ? Color(nsColor: .windowBackgroundColor) : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
        }
    }

    private var chipsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.chips) { chip in
                    chipButton(chip)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
    }

    private func chipButton(_ chip: UniConnectAccountsModel.Chip) -> some View {
        let selected = model.filter == chip.filter
        let tint = chip.colorIndex.map { UniConnectAccountsPalette.color($0) } ?? Color.accentColor
        return Button {
            model.filter = selected ? .all : chip.filter
        } label: {
            HStack(spacing: 6) {
                if chip.colorIndex != nil {
                    Circle().fill(tint).frame(width: 8, height: 8)
                }
                Text(verbatim: chip.title)
                    .font(.system(size: 12, weight: .medium))
                Text(verbatim: "\(chip.count)")
                    .font(.system(size: 11, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(selected ? Color.white.opacity(0.9) : Color.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(selected ? tint : Color.secondary.opacity(0.1)))
            .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private var controls: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(
                    String(localized: "uniconnect.accounts.search", defaultValue: "Buscar espacio, ventana, cuenta, host…"),
                    text: $model.search
                )
                .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            .frame(maxWidth: 360)
            Spacer()
            Picker("", selection: $model.grouping) {
                Text(String(localized: "uniconnect.accounts.group.workspace", defaultValue: "Por espacio"))
                    .tag(UniConnectAccountsModel.Grouping.workspace)
                Text(String(localized: "uniconnect.accounts.group.account", defaultValue: "Por cuenta"))
                    .tag(UniConnectAccountsModel.Grouping.account)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            Toggle(isOn: $model.showWindowsWithoutAgent) {
                Text(String(localized: "uniconnect.accounts.showNoAgent", defaultValue: "Ventanas sin IA"))
            }
            .toggleStyle(.checkbox)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    private func hostWarning(_ host: UniConnectAccountsSnapshot.Host) -> some View {
        let format = Self.hostWarningFormat(host)
        return HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(verbatim: String(format: format, host.label) + (host.errorDetail.map { " · " + $0 } ?? ""))
                .font(.system(size: 12))
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
    }

    /// «No se pudo leer %@: …» with the cause from `hosts[].error`.
    static func hostWarningFormat(_ host: UniConnectAccountsSnapshot.Host) -> String {
        if host.state == .vaultClosed {
            return String(localized: "uniconnect.accounts.host.vaultClosed", defaultValue: "No se pudo leer %@: la bóveda está cerrada")
        }
        switch host.error {
        case "sin_python3":
            return String(localized: "uniconnect.accounts.host.noPython", defaultValue: "No se pudo leer %@: no tiene python3")
        case "ssh_fallo":
            return String(localized: "uniconnect.accounts.host.sshFailed", defaultValue: "No se pudo leer %@: falló la conexión SSH")
        case "salida_no_valida":
            return String(localized: "uniconnect.accounts.host.badOutput", defaultValue: "No se pudo leer %@: respondió algo que no es la sonda")
        case "tmux_no_disponible":
            return String(localized: "uniconnect.accounts.host.noTmux", defaultValue: "No se pudo leer %@: no tiene tmux")
        case "tmux_fallo":
            return String(localized: "uniconnect.accounts.host.tmuxFailed", defaultValue: "No se pudo leer %@: tmux dio un error")
        default:
            return String(localized: "uniconnect.accounts.host.unreachable", defaultValue: "No se pudo leer %@: no contestó a tiempo")
        }
    }

    private var windowList: some View {
        let sections = model.sections
        let byAccount = model.grouping == .account
        let hostLabels = Dictionary(
            (model.snapshot?.hosts ?? []).map { ($0.key, $0.label) },
            uniquingKeysWith: { first, _ in first }
        )
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.rows) { row in
                            UniConnectAccountsRowView(window: row, hostLabel: byAccount ? hostLabels[row.hostKey] : nil)
                            Divider().padding(.leading, 132)
                        }
                    } header: {
                        sectionHeader(section)
                    }
                }
            }
            .padding(.bottom, 16)
        }
    }

    private func sectionHeader(_ section: UniConnectAccountsModel.Section) -> some View {
        HStack(spacing: 8) {
            if let colorIndex = section.colorIndex {
                Circle().fill(UniConnectAccountsPalette.color(colorIndex)).frame(width: 10, height: 10)
            }
            Text(verbatim: section.title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(section.colorIndex.map { UniConnectAccountsPalette.color($0) } ?? Color.primary)
            if let subtitle = section.subtitle {
                Text(verbatim: subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(verbatim: "\(section.rows.count)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 7)
        .background(.bar)
    }
}
