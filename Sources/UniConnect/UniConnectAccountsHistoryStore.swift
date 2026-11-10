import Foundation

/// Usage history of every account (`accounts-v1` §3.1), the only thing «Cuentas de IA» keeps.
///
/// One sample per new `observed_at` of an account, replacing the previous one when it is less than
/// 5 minutes older; 14 days are kept on disk and the last 7 are returned. Readers show it as
/// history with its dates, never as the current state.
actor UniConnectAccountsHistoryStore {
    private struct Document: Codable {
        var version: Int
        var accounts: [String: [UniConnectAccountsSnapshot.HistoryPoint]]
    }

    private let fileURL: URL
    private var accounts: [String: [UniConnectAccountsSnapshot.HistoryPoint]]?

    /// - Parameter fileURL: The JSON file; tests pass a temporary one.
    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Records the current usage of each account and returns its last 7 days, oldest first.
    ///
    /// - Parameters:
    ///   - usages: The usage chosen for each account key, if any.
    ///   - keys: Every account key to return history for, with or without usage now.
    ///   - now: The reading's time.
    func record(
        _ usages: [String: UniConnectAccountsSnapshot.Usage],
        keys: [String],
        now: Date
    ) -> [String: [UniConnectAccountsSnapshot.HistoryPoint]] {
        var stored = load()
        var changed = false
        for (key, usage) in usages {
            let point = UniConnectAccountsSnapshot.HistoryPoint(
                at: usage.observedAt,
                limits: Dictionary(usage.limits.map { ($0.id, $0.usedPercent) }, uniquingKeysWith: { first, _ in first })
            )
            var points = stored[key] ?? []
            if let last = points.last {
                guard usage.observedAt > last.at else { continue }
                if usage.observedAt.timeIntervalSince(last.at) < 5 * 60 {
                    points[points.count - 1] = point
                } else {
                    points.append(point)
                }
            } else {
                points.append(point)
            }
            stored[key] = points
            changed = true
        }
        let keepFrom = now.addingTimeInterval(-14 * 86_400)
        for (key, points) in stored {
            let kept = points.filter { $0.at >= keepFrom }
            if kept.count != points.count {
                stored[key] = kept.isEmpty ? nil : kept
                changed = true
            }
        }
        accounts = stored
        if changed { save(stored) }
        let showFrom = now.addingTimeInterval(-7 * 86_400)
        var result: [String: [UniConnectAccountsSnapshot.HistoryPoint]] = [:]
        for key in keys {
            result[key] = (stored[key] ?? []).filter { $0.at >= showFrom }
        }
        return result
    }

    private func load() -> [String: [UniConnectAccountsSnapshot.HistoryPoint]] {
        if let accounts { return accounts }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let document = try? decoder.decode(Document.self, from: data),
              document.version == 1 else { return [:] }
        return document.accounts
    }

    private func save(_ accounts: [String: [UniConnectAccountsSnapshot.HistoryPoint]]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Document(version: 1, accounts: accounts)) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
