import Foundation
import Observation

/// State of the «Cuentas de IA» window: the last reading, filters, grouping and auto-refresh.
///
/// Every refresh is a new live reading (``UniConnectAccountsReader``); the window never shows a
/// previous reading as current. It refreshes on open, every 15 s while visible, and on demand.
@MainActor
@Observable
final class UniConnectAccountsModel {
    enum Tab: Hashable {
        case windows
        case usage
    }

    enum Grouping: Hashable {
        case workspace
        case account
    }

    enum Filter: Hashable {
        case all
        case email(String)
        case noSession
        case unread
    }

    /// One filter chip: «Todas · 34», «dev@notbetting.com · 28»…
    struct Chip: Identifiable, Equatable {
        let filter: Filter
        let title: String
        let count: Int
        /// Palette index for an email chip.
        let colorIndex: Int?
        var id: Filter { filter }
    }

    /// One group of rows under a header.
    struct Section: Identifiable, Equatable {
        let id: String
        let title: String
        let subtitle: String?
        let colorIndex: Int?
        let rows: [UniConnectAccountsSnapshot.Window]
    }

    private(set) var snapshot: UniConnectAccountsSnapshot?
    private(set) var isLoading = false
    var tab: Tab = .windows
    var filter: Filter = .all
    var search = ""
    var grouping: Grouping = .workspace
    var showWindowsWithoutAgent = false
    /// The account open in «Uso por cuenta»; `nil` is «Resumen».
    var selectedAccountKey: String?
    var alwaysOnTop = false

    /// The Codex account whose free reset is being spent, if any.
    private(set) var resettingKey: String?

    private let load: @MainActor () async -> UniConnectAccountsSnapshot?
    private let codexReset: @MainActor (UniConnectAccountsSnapshot.AccountSummary) async -> Bool
    private var refreshTask: Task<Void, Never>?
    private var autoRefreshTask: Task<Void, Never>?

    /// - Parameters:
    ///   - load: One live reading of every open window; the coordinator passes it.
    ///   - codexReset: Confirms and spends one free Codex reset (`accounts-v1` §5); returns
    ///     whether one was attempted.
    init(
        load: @escaping @MainActor () async -> UniConnectAccountsSnapshot?,
        codexReset: @escaping @MainActor (UniConnectAccountsSnapshot.AccountSummary) async -> Bool = { _ in false }
    ) {
        self.load = load
        self.codexReset = codexReset
    }

    /// «Usar un reseteo gratis»: asks, spends it, and reads the accounts again.
    func spendCodexReset(_ account: UniConnectAccountsSnapshot.AccountSummary) {
        guard resettingKey == nil else { return }
        resettingKey = account.key
        Task { [weak self] in
            guard let self else { return }
            let attempted = await self.codexReset(account)
            self.resettingKey = nil
            if attempted { self.refresh() }
        }
    }

    /// Starts a live reading unless one is already running.
    func refresh() {
        guard refreshTask == nil else { return }
        isLoading = true
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let reading = await self.load()
            if let reading { self.snapshot = reading }
            self.isLoading = false
            self.refreshTask = nil
        }
    }

    /// Reads now and then every 15 s, until ``stopAutoRefresh()``.
    func startAutoRefresh() {
        guard autoRefreshTask == nil else { return }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                // Intended period between live readings while the window is visible; cancelled
                // when it closes or is hidden.
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    /// Stops the periodic readings (window closed, minimized or hidden).
    func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    // MARK: - Derived

    /// Windows after «Ventanas sin IA».
    var baseWindows: [UniConnectAccountsSnapshot.Window] {
        guard let snapshot else { return [] }
        return showWindowsWithoutAgent ? snapshot.windows : snapshot.windows.filter { !$0.state.isWithoutAgent }
    }

    /// «Todas», one chip per email (most windows first), «Sin sesión» and «Sin leer».
    var chips: [Chip] {
        let windows = baseWindows
        var counts: [String: Int] = [:]
        for window in windows where window.state == .ok {
            if let email = window.account?.email { counts[email, default: 0] += 1 }
        }
        var chips = [Chip(
            filter: .all,
            title: String(localized: "uniconnect.accounts.filter.all", defaultValue: "Todas"),
            count: windows.count,
            colorIndex: nil
        )]
        let ordered: [(email: String, count: Int)] = counts
            .map { (email: $0.key, count: $0.value) }
            .sorted { left, right in left.count != right.count ? left.count > right.count : left.email < right.email }
        for entry in ordered {
            let index = UniConnectAccountsUsageMath.colorIndex(email: entry.email)
            chips.append(Chip(filter: .email(entry.email), title: entry.email, count: entry.count, colorIndex: index))
        }
        let noSession = windows.filter { $0.state == .noSession }.count
        if noSession > 0 {
            chips.append(Chip(
                filter: .noSession,
                title: String(localized: "uniconnect.accounts.filter.noSession", defaultValue: "Sin sesión"),
                count: noSession, colorIndex: nil
            ))
        }
        let unread = windows.filter { $0.state.isUnread }.count
        if unread > 0 {
            chips.append(Chip(
                filter: .unread,
                title: String(localized: "uniconnect.accounts.filter.unread", defaultValue: "Sin leer"),
                count: unread, colorIndex: nil
            ))
        }
        return chips
    }

    /// Windows after the chip and the search.
    var visibleWindows: [UniConnectAccountsSnapshot.Window] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return baseWindows.filter { window in
            switch filter {
            case .all: break
            case .email(let email): guard window.state == .ok, window.account?.email == email else { return false }
            case .noSession: guard window.state == .noSession else { return false }
            case .unread: guard window.state.isUnread else { return false }
            }
            guard !query.isEmpty else { return true }
            let haystack = [
                window.workspace, window.window, window.account?.email, window.account?.osUser,
                snapshot?.host(window.hostKey)?.label, window.agent?.displayName,
            ].compactMap { $0?.lowercased() }
            return haystack.contains { $0.contains(query) }
        }
    }

    /// Rows grouped by workspace (sidebar order) or by account (most windows first).
    var sections: [Section] {
        let rows = visibleWindows
        switch grouping {
        case .workspace:
            var order: [UUID] = []
            var grouped: [UUID: [UniConnectAccountsSnapshot.Window]] = [:]
            for row in rows {
                if grouped[row.workspaceID] == nil { order.append(row.workspaceID) }
                grouped[row.workspaceID, default: []].append(row)
            }
            return order.compactMap { id in
                guard let members = grouped[id], let first = members.first else { return nil }
                return Section(
                    id: id.uuidString, title: first.workspace,
                    subtitle: snapshot?.host(first.hostKey)?.label, colorIndex: nil, rows: members
                )
            }
        case .account:
            var order: [String] = []
            var grouped: [String: [UniConnectAccountsSnapshot.Window]] = [:]
            for row in rows {
                let key = Self.accountGroupKey(row)
                if grouped[key] == nil { order.append(key) }
                grouped[key, default: []].append(row)
            }
            order.sort { left, right in
                let leftEmail = left.hasPrefix("@"), rightEmail = right.hasPrefix("@")
                if leftEmail != rightEmail { return leftEmail }
                let leftCount = grouped[left]?.count ?? 0, rightCount = grouped[right]?.count ?? 0
                return leftCount != rightCount ? leftCount > rightCount : left < right
            }
            return order.compactMap { key in
                guard let members = grouped[key] else { return nil }
                let email = key.hasPrefix("@") ? String(key.dropFirst()) : nil
                let hosts = Set(members.map(\.hostKey)).count
                let format = String(
                    localized: "uniconnect.accounts.section.accountSubtitle",
                    defaultValue: "%1$lld ventanas · %2$lld hosts"
                )
                return Section(
                    id: key,
                    title: email ?? Self.stateTitle(key),
                    subtitle: String.localizedStringWithFormat(format, Int64(members.count), Int64(hosts)),
                    colorIndex: email.map { UniConnectAccountsUsageMath.colorIndex(email: $0) },
                    rows: members
                )
            }
        }
    }

    /// Hosts that could not be read in the last reading.
    var hostWarnings: [UniConnectAccountsSnapshot.Host] {
        (snapshot?.hosts ?? []).filter { $0.state != .ok }
    }

    /// The account open in «Uso por cuenta», if any.
    var selectedAccount: UniConnectAccountsSnapshot.AccountSummary? {
        guard let selectedAccountKey else { return nil }
        return snapshot?.accounts.first { $0.key == selectedAccountKey }
    }

    /// Shows the windows of one account in «Ventanas».
    func showWindows(ofEmail email: String) {
        filter = .email(email)
        tab = .windows
    }

    private static func accountGroupKey(_ window: UniConnectAccountsSnapshot.Window) -> String {
        if window.state == .ok, let email = window.account?.email { return "@" + email }
        if window.state == .ok, let method = window.account?.method { return "#method:" + method }
        if window.state == .noSession { return "#sin_sesion" }
        if window.state.isUnread { return "#sin_leer" }
        return "#sin_ia"
    }

    private static func stateTitle(_ key: String) -> String {
        switch key {
        case "#sin_sesion": String(localized: "uniconnect.accounts.filter.noSession", defaultValue: "Sin sesión")
        case "#sin_leer": String(localized: "uniconnect.accounts.filter.unread", defaultValue: "Sin leer")
        case "#method:api_key": String(localized: "uniconnect.accounts.method.apiKey", defaultValue: "Clave de API")
        case "#method:bedrock": "Bedrock"
        case "#method:vertex": "Vertex"
        case "#method:foundry": "Foundry"
        default: String(localized: "uniconnect.accounts.section.noAgent", defaultValue: "Sin IA")
        }
    }
}
