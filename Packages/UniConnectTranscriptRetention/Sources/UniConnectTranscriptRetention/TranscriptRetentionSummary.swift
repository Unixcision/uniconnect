/// What one retention pass did.
public struct TranscriptRetentionSummary: Sendable, Equatable {
    /// Transcripts compressed into `.jsonl.gz`.
    public var compressed = 0

    /// Transcripts deleted.
    public var deleted = 0

    /// Transcripts left for the next pass because they changed while being compressed.
    public var postponed = 0

    /// Files that could not be handled; the pass goes on with the rest.
    public var failures = 0

    /// Bytes the disk got back.
    public var bytesFreed: Int64 = 0

    /// Creates an empty summary.
    public init() {}
}
