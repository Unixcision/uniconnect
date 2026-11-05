/// One file under a transcript root, as the planner sees it.
public struct TranscriptEntry: Sendable, Equatable {
    /// The logical path: the root's name, then the path inside it (`claude/<project>/<uuid>.jsonl`).
    public var path: String

    /// Days since the file last changed.
    public var ageDays: Double

    /// Creates an entry.
    /// - Parameters:
    ///   - path: the logical path, starting with the root's name.
    ///   - ageDays: days since the last modification.
    public init(path: String, ageDays: Double) {
        self.path = path
        self.ageDays = ageDays
    }
}
