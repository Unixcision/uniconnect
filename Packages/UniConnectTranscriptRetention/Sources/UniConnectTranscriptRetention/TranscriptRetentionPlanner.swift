/// Decides, without touching the disk, what a retention pass does.
///
/// This is the rule of `contracts/transcript-retention-v1`, which the Linux edition implements
/// the same way and both test against `cases.json`:
///
/// - only `.jsonl` and `.jsonl.gz` count;
/// - a path containing a protected conversation id is never touched;
/// - over ``TranscriptRetentionPolicy/deleteAfterDays`` it is deleted;
/// - a `.jsonl` over ``TranscriptRetentionPolicy/compressAfterDays`` is compressed, even when a
///   `.gz` of an earlier archive sits next to it.
///
/// ```swift
/// let plan = TranscriptRetentionPlanner().plan(
///     entries: [TranscriptEntry(path: "claude/-Users-dani/<uuid>.jsonl", ageDays: 45)],
///     protected: []
/// )
/// // plan.compress == ["claude/-Users-dani/<uuid>.jsonl"]
/// ```
public struct TranscriptRetentionPlanner: Sendable {
    /// The thresholds applied.
    public let policy: TranscriptRetentionPolicy

    private let scanner = ConversationIDScanner()

    /// Creates a planner.
    /// - Parameter policy: the thresholds; defaults to 30 and 365 days.
    public init(policy: TranscriptRetentionPolicy = TranscriptRetentionPolicy()) {
        self.policy = policy
    }

    /// What to compress and delete among `entries`.
    /// - Parameters:
    ///   - entries: every file found under the roots.
    ///   - protected: conversation ids in use, in any case.
    /// - Returns: the logical paths to compress and to delete, sorted.
    public func plan(entries: [TranscriptEntry], protected: Set<String>) -> TranscriptRetentionPlan {
        let protected = Set(protected.map { $0.lowercased() })
        var plan = TranscriptRetentionPlan()
        for entry in entries {
            let plain = entry.path.hasSuffix(".jsonl")
            guard plain || entry.path.hasSuffix(".jsonl.gz") else { continue }
            guard scanner.ids(in: entry.path).isDisjoint(with: protected) else { continue }
            if entry.ageDays > policy.deleteAfterDays {
                plan.delete.append(entry.path)
            } else if plain, entry.ageDays > policy.compressAfterDays {
                plan.compress.append(entry.path)
            }
        }
        plan.compress.sort()
        plan.delete.sort()
        return plan
    }
}
