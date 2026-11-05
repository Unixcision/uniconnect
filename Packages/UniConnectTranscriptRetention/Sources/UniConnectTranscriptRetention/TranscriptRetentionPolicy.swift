/// How long AI transcripts stay as they are, compressed, or at all.
///
/// The defaults are the rule Dani chose on 5-11-2026 and the one `contracts/transcript-retention-v1`
/// fixes for macOS and Linux alike.
public struct TranscriptRetentionPolicy: Sendable, Equatable {
    /// Days without a change after which a `.jsonl` is compressed in place. Strict: 30 days
    /// exactly is not yet over the limit.
    public var compressAfterDays: Double

    /// Days without a change after which a transcript is deleted, compressed or not.
    public var deleteAfterDays: Double

    /// Creates a policy.
    /// - Parameters:
    ///   - compressAfterDays: defaults to 30, a month of plain, resumable context.
    ///   - deleteAfterDays: defaults to 365, a year of context in all.
    public init(compressAfterDays: Double = 30, deleteAfterDays: Double = 365) {
        self.compressAfterDays = compressAfterDays
        self.deleteAfterDays = deleteAfterDays
    }
}
