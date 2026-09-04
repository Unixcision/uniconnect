import Foundation

/// Defines the cadence and bounded retention of automatic session recovery points.
struct UniConnectRecoveryBackupPolicy: Sendable, Equatable {
    static let standard = UniConnectRecoveryBackupPolicy(
        interval: 6 * 60 * 60,
        retention: 7 * 24 * 60 * 60,
        maximumCount: 28,
        maximumBeforeRestoreCount: 7
    )

    let interval: TimeInterval
    let retention: TimeInterval
    let maximumCount: Int
    let maximumBeforeRestoreCount: Int

    init(
        interval: TimeInterval,
        retention: TimeInterval,
        maximumCount: Int,
        maximumBeforeRestoreCount: Int = 7
    ) {
        self.interval = max(1, interval)
        self.retention = max(1, retention)
        self.maximumCount = max(1, maximumCount)
        self.maximumBeforeRestoreCount = max(1, maximumBeforeRestoreCount)
    }

    func isScheduledBackupDue(lastScheduledAt: Date?, now: Date) -> Bool {
        guard let lastScheduledAt else { return true }
        return now.timeIntervalSince(lastScheduledAt) >= interval
    }

    func retainedIndices(for datesNewestFirst: [Date], now: Date) -> Set<Int> {
        retainedIndices(
            for: datesNewestFirst,
            now: now,
            maximumCount: maximumCount
        )
    }

    func retainedBeforeRestoreIndices(for datesNewestFirst: [Date], now: Date) -> Set<Int> {
        retainedIndices(
            for: datesNewestFirst,
            now: now,
            maximumCount: maximumBeforeRestoreCount
        )
    }

    private func retainedIndices(
        for datesNewestFirst: [Date],
        now: Date,
        maximumCount: Int
    ) -> Set<Int> {
        let cutoff = now.addingTimeInterval(-retention)
        var retained: Set<Int> = []
        for index in datesNewestFirst.indices {
            let date = datesNewestFirst[index]
            guard date >= cutoff, date <= now else { continue }
            guard retained.count < maximumCount else { break }
            retained.insert(index)
        }
        return retained
    }
}
