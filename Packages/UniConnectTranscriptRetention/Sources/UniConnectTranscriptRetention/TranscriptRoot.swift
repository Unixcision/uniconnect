public import Foundation

/// A folder of AI transcripts and the name its files carry in logical paths.
public struct TranscriptRoot: Sendable, Equatable {
    /// The first component of logical paths under this root (`claude`, `codex`).
    public var name: String

    /// The folder on disk. It is never deleted, even when it ends up empty.
    public var url: URL

    /// Creates a root.
    /// - Parameters:
    ///   - name: the logical name.
    ///   - url: the folder on disk.
    public init(name: String, url: URL) {
        self.name = name
        self.url = url
    }

    /// Claude Code (`~/.claude/projects`) and Codex (`~/.codex/sessions`) under `home`.
    /// - Parameter home: the home of the user the AIs run as.
    public static func aiTranscripts(home: URL) -> [TranscriptRoot] {
        [
            TranscriptRoot(name: "claude", url: home.appendingPathComponent(".claude/projects", isDirectory: true)),
            TranscriptRoot(name: "codex", url: home.appendingPathComponent(".codex/sessions", isDirectory: true)),
        ]
    }
}
