/// What one retention pass will do, by logical path, sorted.
public struct TranscriptRetentionPlan: Sendable, Equatable {
    /// `.jsonl` files to compress in place into `.jsonl.gz`.
    public var compress: [String]

    /// Files to delete, compressed or not.
    public var delete: [String]

    /// Creates a plan.
    /// - Parameters:
    ///   - compress: logical paths to compress.
    ///   - delete: logical paths to delete.
    public init(compress: [String] = [], delete: [String] = []) {
        self.compress = compress
        self.delete = delete
    }
}
