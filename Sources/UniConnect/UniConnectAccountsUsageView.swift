import Charts
import SwiftUI

/// «Uso por cuenta» (`accounts-v1` §4.1): one tab per account with its limits, resets, a 7-day
/// chart, rate and projection, plus a «Resumen» grid of every account.
struct UniConnectAccountsUsageView: View {
    let snapshot: UniConnectAccountsSnapshot?
    /// The accounts to list, already filtered by provider.
    let accounts: [UniConnectAccountsSnapshot.AccountSummary]
    @Binding var selectedKey: String?
    /// The Codex account whose reset is being spent, to disable its button.
    let resettingKey: String?
    let onShowWindows: (String) -> Void
    let onCodexReset: (UniConnectAccountsSnapshot.AccountSummary) -> Void

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 270)
            Divider()
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let math = UniConnectAccountsUsageMath(now: context.date)
                ScrollView {
                    if let account = selectedAccount {
                        detail(account, math: math)
                            .padding(24)
                    } else {
                        summary(math: math)
                            .padding(24)
                    }
                }
            }
        }
    }

    private var selectedAccount: UniConnectAccountsSnapshot.AccountSummary? {
        guard let selectedKey else { return nil }
        return accounts.first { $0.key == selectedKey }
    }

    private func hostLabel(_ key: String?) -> String? {
        guard let key else { return nil }
        return snapshot?.host(key)?.label
    }

    // MARK: Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                sidebarRow(
                    key: nil,
                    title: String(localized: "uniconnect.accounts.usage.summary", defaultValue: "Resumen"),
                    subtitle: {
                        let format = String(localized: "uniconnect.accounts.usage.accountsCount", defaultValue: "%lld cuentas")
                        return String.localizedStringWithFormat(format, Int64(accounts.count))
                    }(),
                    color: .accentColor,
                    percent: nil
                )
                ForEach(accounts) { account in
                    sidebarRow(
                        key: account.key,
                        title: account.email,
                        subtitle: [account.displayName, account.plan].compactMap { $0 }.joined(separator: " · "),
                        color: UniConnectAccountsPalette.color(email: account.email),
                        percent: highestPercent(account)
                    )
                }
            }
            .padding(10)
        }
    }

    private func sidebarRow(key: String?, title: String, subtitle: String, color: Color, percent: Double?) -> some View {
        let selected = selectedKey == key
        return Button {
            selectedKey = key
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(verbatim: subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let percent {
                    UniConnectAccountsGauge(percent: percent, size: 30, lineWidth: 4, showsLabel: false)
                        .overlay(
                            Text(verbatim: "\(Int(percent.rounded()))")
                                .font(.system(size: 9, weight: .bold))
                                .monospacedDigit()
                        )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.15) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The fullest limit right now (a past reset counts as 0).
    private func highestPercent(_ account: UniConnectAccountsSnapshot.AccountSummary) -> Double? {
        guard let usage = account.usage else { return nil }
        let math = UniConnectAccountsUsageMath(now: Date())
        return usage.limits.map { math.reading($0).percent }.max()
    }

    // MARK: Summary

    private func summary(math: UniConnectAccountsUsageMath) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "uniconnect.accounts.usage.summaryTitle", defaultValue: "Todas las cuentas"))
                .font(.system(size: 18, weight: .bold))
            if accounts.isEmpty {
                Text(String(localized: "uniconnect.accounts.usage.noAccounts", defaultValue: "Todavía no hay ninguna cuenta leída."))
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
                ForEach(accounts) { account in
                    Button {
                        selectedKey = account.key
                    } label: {
                        summaryCard(account, math: math)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func summaryCard(_ account: UniConnectAccountsSnapshot.AccountSummary, math: UniConnectAccountsUsageMath) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(UniConnectAccountsPalette.color(email: account.email)).frame(width: 9, height: 9)
                Text(verbatim: account.email)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(UniConnectAccountsPalette.color(email: account.email))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(verbatim: [account.displayName, account.plan, windowsText(account)].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if let usage = account.usage {
                HStack(spacing: 16) {
                    ForEach(usage.limits, id: \.id) { limit in
                        let reading = math.reading(limit)
                        VStack(spacing: 4) {
                            UniConnectAccountsGauge(percent: reading.percent, size: 58, lineWidth: 7)
                            Text(verbatim: UniConnectAccountsUsageMath.label(id: limit.id, windowMinutes: limit.windowMinutes))
                                .font(.system(size: 10, weight: .medium))
                            if let resetsAt = limit.resetsAt, !reading.wasReset {
                                Text(verbatim: math.remaining(until: resetsAt))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Text(verbatim: seenText(usage, math: math))
                    .font(.system(size: 10))
                    .foregroundStyle(math.isOld(usage.observedAt) ? Color.orange : Color.secondary)
                if let credits = usage.resetCredits {
                    let format = String(localized: "uniconnect.accounts.usage.resetCredits", defaultValue: "%lld reseteos gratis disponibles")
                    Label(String.localizedStringWithFormat(format, Int64(credits.available)), systemImage: "gift.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(UniConnectAccountsPalette.color(2))
                }
            } else {
                Text(verbatim: noUsageText(account))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(UniConnectAccountsPalette.color(email: account.email).opacity(0.35)))
    }

    // MARK: Detail

    private func detail(_ account: UniConnectAccountsSnapshot.AccountSummary, math: UniConnectAccountsUsageMath) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle().fill(UniConnectAccountsPalette.color(email: account.email)).frame(width: 12, height: 12)
                    Text(verbatim: account.email)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(UniConnectAccountsPalette.color(email: account.email))
                        .textSelection(.enabled)
                    if let plan = account.plan {
                        Text(verbatim: plan)
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().strokeBorder(Color.secondary.opacity(0.4)))
                    }
                }
                Text(verbatim: [account.displayName, account.organization, windowsText(account)].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            if let usage = account.usage {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 400), spacing: 14)], spacing: 14) {
                    ForEach(usage.limits, id: \.id) { limit in
                        limitCard(limit, usage: usage, history: account.history, math: math)
                    }
                }
                Text(verbatim: seenText(usage, math: math))
                    .font(.system(size: 11))
                    .foregroundStyle(math.isOld(usage.observedAt) ? Color.orange : Color.secondary)
                if let credits = usage.resetCredits {
                    HStack(spacing: 12) {
                        resetCreditsBadge(credits)
                        if account.provider == "codex", credits.available > 0 {
                            Button {
                                onCodexReset(account)
                            } label: {
                                HStack(spacing: 6) {
                                    if resettingKey == account.key {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Image(systemName: "arrow.counterclockwise.circle.fill")
                                    }
                                    Text(String(localized: "uniconnect.accounts.reset.button", defaultValue: "Usar un reseteo gratis"))
                                }
                            }
                            .disabled(resettingKey != nil)
                        }
                    }
                }
            } else {
                Text(verbatim: noUsageText(account))
                    .foregroundStyle(.secondary)
            }
            chart(account)
            whereSection(account)
        }
    }

    private func limitCard(
        _ limit: UniConnectAccountsSnapshot.Limit,
        usage: UniConnectAccountsSnapshot.Usage,
        history: [UniConnectAccountsSnapshot.HistoryPoint],
        math: UniConnectAccountsUsageMath
    ) -> some View {
        let reading = math.reading(limit)
        let projection = math.projection(limit: limit, observedAt: usage.observedAt, history: history)
        return HStack(alignment: .center, spacing: 16) {
            UniConnectAccountsGauge(percent: reading.percent, size: 92, lineWidth: 10)
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: UniConnectAccountsUsageMath.label(id: limit.id, windowMinutes: limit.windowMinutes))
                    .font(.system(size: 14, weight: .bold))
                if reading.wasReset, let resetsAt = limit.resetsAt {
                    let format = String(localized: "uniconnect.accounts.usage.wasReset", defaultValue: "Reseteado el %@ · sin uso nuevo visto")
                    Text(verbatim: String(format: format, UniConnectAccountsUsageMath.weekdayTime(resetsAt)))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if let resetsAt = limit.resetsAt {
                    let format = String(localized: "uniconnect.accounts.usage.resetsIn", defaultValue: "Resetea en %1$@ · %2$@")
                    Text(verbatim: String(format: format, math.remaining(until: resetsAt), UniConnectAccountsUsageMath.weekdayTime(resetsAt)))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if let projection, !reading.wasReset {
                    let rateFormat = String(localized: "uniconnect.accounts.usage.rate", defaultValue: "Ritmo: %@ puntos al día")
                    Text(verbatim: String(format: rateFormat, projection.perDay.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "es_ES")))))
                        .font(.system(size: 11))
                    if let exhaustion = projection.exhaustion {
                        let format = String(localized: "uniconnect.accounts.usage.exhaustion", defaultValue: "Se agotaría el %@")
                        Text(verbatim: String(format: format, UniConnectAccountsUsageMath.weekdayTime(exhaustion)))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(UniConnectAccountsPalette.color(0))
                    } else {
                        let format = String(localized: "uniconnect.accounts.usage.projection", defaultValue: "A este ritmo, llegarás al %lld %% antes del reset")
                        Text(verbatim: String.localizedStringWithFormat(format, Int64(max(0, projection.atReset).rounded())))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.07)))
    }

    private struct ChartPoint: Identifiable {
        let id: String
        let at: Date
        let percent: Double
        let label: String
    }

    @ViewBuilder
    private func chart(_ account: UniConnectAccountsSnapshot.AccountSummary) -> some View {
        let points = chartPoints(account)
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "uniconnect.accounts.usage.chartTitle", defaultValue: "Últimos 7 días"))
                .font(.system(size: 14, weight: .bold))
            if points.count < 2 {
                Text(String(localized: "uniconnect.accounts.usage.chartEmpty", defaultValue: "La gráfica se irá llenando con cada lectura de uso."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            } else {
                Chart {
                    ForEach(points) { point in
                        LineMark(
                            x: .value(String(localized: "uniconnect.accounts.usage.chartTime", defaultValue: "Hora"), point.at),
                            y: .value(String(localized: "uniconnect.accounts.usage.chartPercent", defaultValue: "Uso"), point.percent)
                        )
                        .foregroundStyle(by: .value(String(localized: "uniconnect.accounts.usage.chartLimit", defaultValue: "Límite"), point.label))
                        .interpolationMethod(.monotone)
                        PointMark(
                            x: .value(String(localized: "uniconnect.accounts.usage.chartTime", defaultValue: "Hora"), point.at),
                            y: .value(String(localized: "uniconnect.accounts.usage.chartPercent", defaultValue: "Uso"), point.percent)
                        )
                        .foregroundStyle(by: .value(String(localized: "uniconnect.accounts.usage.chartLimit", defaultValue: "Límite"), point.label))
                        .symbolSize(14)
                    }
                    ForEach(resetDates(account), id: \.self) { date in
                        RuleMark(x: .value(String(localized: "uniconnect.accounts.usage.chartReset", defaultValue: "Reset"), date))
                            .foregroundStyle(Color.secondary.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                }
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                        AxisGridLine()
                        AxisValueLabel { Text(verbatim: "\(value.as(Int.self) ?? 0) %") }
                    }
                }
                .frame(height: 220)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.07)))
    }

    private func chartPoints(_ account: UniConnectAccountsSnapshot.AccountSummary) -> [ChartPoint] {
        var points: [ChartPoint] = []
        var windows: [String: Int?] = [:]
        for limit in account.usage?.limits ?? [] { windows[limit.id] = limit.windowMinutes }
        for point in account.history {
            for (id, percent) in point.limits {
                let label = UniConnectAccountsUsageMath.label(id: id, windowMinutes: windows[id] ?? nil)
                points.append(ChartPoint(id: "\(id)-\(point.at.timeIntervalSince1970)", at: point.at, percent: percent, label: label))
            }
        }
        if let usage = account.usage {
            for limit in usage.limits where !points.contains(where: { $0.at == usage.observedAt && $0.label == UniConnectAccountsUsageMath.label(id: limit.id, windowMinutes: limit.windowMinutes) }) {
                let label = UniConnectAccountsUsageMath.label(id: limit.id, windowMinutes: limit.windowMinutes)
                points.append(ChartPoint(id: "\(limit.id)-now", at: usage.observedAt, percent: limit.usedPercent, label: label))
            }
        }
        return points.sorted { $0.at < $1.at }
    }

    private func resetDates(_ account: UniConnectAccountsSnapshot.AccountSummary) -> [Date] {
        let from = Date().addingTimeInterval(-7 * 86_400)
        let to = Date().addingTimeInterval(86_400)
        return Array(Set((account.usage?.limits ?? []).compactMap(\.resetsAt).filter { $0 >= from && $0 <= to })).sorted()
    }

    // MARK: Where

    private func whereSection(_ account: UniConnectAccountsSnapshot.AccountSummary) -> some View {
        let windows = (snapshot?.windows ?? []).filter { window in
            window.state == .ok && window.account?.email == account.email && window.agent?.provider == account.provider
        }
        var order: [String] = []
        var byHost: [String: [UniConnectAccountsSnapshot.Window]] = [:]
        for window in windows {
            if byHost[window.hostKey] == nil { order.append(window.hostKey) }
            byHost[window.hostKey, default: []].append(window)
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(String(localized: "uniconnect.accounts.usage.where", defaultValue: "Dónde está"))
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                Button(String(localized: "uniconnect.accounts.usage.showWindows", defaultValue: "Ver sus ventanas")) {
                    onShowWindows(account.email)
                }
                .buttonStyle(.link)
            }
            ForEach(order, id: \.self) { key in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: hostLabel(key) ?? key)
                        .font(.system(size: 12, weight: .semibold))
                    Text(verbatim: (byHost[key] ?? []).map { "\($0.workspace) / \($0.window)" }.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.07)))
    }

    private func resetCreditsBadge(_ credits: UniConnectAccountsSnapshot.ResetCredits) -> some View {
        let format = String(localized: "uniconnect.accounts.usage.resetCredits", defaultValue: "%lld reseteos gratis disponibles")
        var text = String.localizedStringWithFormat(format, Int64(credits.available))
        if let expires = credits.nextExpiresAt {
            let expiresFormat = String(localized: "uniconnect.accounts.usage.resetCreditsExpire", defaultValue: "el primero caduca el %@")
            text += " · " + String(format: expiresFormat, expires.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "es_ES"))))
        }
        return HStack(spacing: 8) {
            Image(systemName: "gift.fill").foregroundStyle(UniConnectAccountsPalette.color(2))
            Text(verbatim: text).font(.system(size: 12, weight: .semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(UniConnectAccountsPalette.color(2).opacity(0.12)))
    }

    // MARK: Texts

    private func windowsText(_ account: UniConnectAccountsSnapshot.AccountSummary) -> String {
        let format = String(localized: "uniconnect.accounts.section.accountSubtitle", defaultValue: "%1$lld ventanas · %2$lld hosts")
        return String.localizedStringWithFormat(format, Int64(account.windows), Int64(account.hostKeys.count))
    }

    private func seenText(_ usage: UniConnectAccountsSnapshot.Usage, math: UniConnectAccountsUsageMath) -> String {
        let format = String(localized: "uniconnect.accounts.usage.seen", defaultValue: "Visto %1$@ en %2$@")
        return String(format: format, math.age(of: usage.observedAt), hostLabel(usage.hostKey) ?? "—")
    }

    private func noUsageText(_ account: UniConnectAccountsSnapshot.AccountSummary) -> String {
        account.provider == "codex"
            ? String(localized: "uniconnect.accounts.usage.noneCodex", defaultValue: "Sin datos de uso todavía: aparecen en cuanto Codex haga una petición.")
            : String(localized: "uniconnect.accounts.usage.noneClaude", defaultValue: "Sin datos de uso todavía: aparecen en cuanto esta cuenta trabaje en una ventana con la barra de estado de UniConnect.")
    }
}
