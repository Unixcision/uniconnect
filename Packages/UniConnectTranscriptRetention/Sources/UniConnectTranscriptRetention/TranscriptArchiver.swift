public import Foundation
import os

/// Keeps the AI transcripts of this machine within ``TranscriptRetentionPolicy``.
///
/// Every pass scans the roots, asks ``TranscriptRetentionPlanner`` what to do and does it without
/// ever losing a line (see `contracts/transcript-retention-v1/LEEME.md`):
///
/// 1. The `.jsonl` is compressed into `<x>.jsonl.gz.tmp`, which starts as a copy of an existing
///    `.gz` when there is one, so a resumed conversation is appended to its archive.
/// 2. The temporary file is verified.
/// 3. If the original changed meanwhile, the temporary file is dropped and the transcript is
///    left for the next pass.
/// 4. The temporary file takes the original's date and permissions and replaces `<x>.jsonl.gz`;
///    only then is the original removed.
/// 5. Folders left empty inside a root are removed; a root never is.
///
/// ```swift
/// let archiver = TranscriptArchiver(
///     roots: TranscriptRoot.aiTranscripts(home: FileManager.default.homeDirectoryForCurrentUser),
///     protectedConversations: { await appState.conversationIDs() }
/// )
/// let task = Task { await archiver.run() }   // hourly until cancelled
/// ```
public actor TranscriptArchiver {
    private let roots: [TranscriptRoot]
    private let planner: TranscriptRetentionPlanner
    private let compressor: any TranscriptCompressing
    private let protectedConversations: @Sendable () async -> Set<String>?
    private let now: @Sendable () -> Date
    private let log = Logger(subsystem: "com.unixcision.uniconnect", category: "transcript-retention")

    /// Creates an archiver.
    /// - Parameters:
    ///   - roots: the transcript folders; see ``TranscriptRoot/aiTranscripts(home:)``.
    ///   - policy: the thresholds; defaults to 30 and 365 days.
    ///   - compressor: the gzip seam; defaults to the system's `gzip`.
    ///   - protectedConversations: the conversation ids in use (UniConnect's windows and live
    ///     AIs), asked once per pass. Nil when they cannot be known right now: the pass is skipped
    ///     rather than run without protecting anything.
    ///   - now: the clock ages are measured against.
    public init(
        roots: [TranscriptRoot],
        policy: TranscriptRetentionPolicy = TranscriptRetentionPolicy(),
        compressor: any TranscriptCompressing = GzipTranscriptCompressor(),
        protectedConversations: @escaping @Sendable () async -> Set<String>?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.roots = roots
        self.planner = TranscriptRetentionPlanner(policy: policy)
        self.compressor = compressor
        self.protectedConversations = protectedConversations
        self.now = now
    }

    /// Runs a pass now.
    /// - Returns: what it did.
    @discardableResult
    public func runOnce() async -> TranscriptRetentionSummary {
        guard let protected = await protectedConversations() else { return TranscriptRetentionSummary() }
        let plan = planner.plan(entries: scan(reference: now()), protected: protected)
        var summary = TranscriptRetentionSummary()
        var emptied = Set<URL>()
        for path in plan.delete {
            guard let url = fileURL(for: path) else { continue }
            let size = fileSize(url)
            do {
                try FileManager.default.removeItem(at: url)
                summary.deleted += 1
                summary.bytesFreed += size
                emptied.insert(url.deletingLastPathComponent())
            } catch {
                summary.failures += 1
            }
        }
        for path in plan.compress {
            guard let url = fileURL(for: path) else { continue }
            await compress(url, into: &summary)
        }
        removeEmptyFolders(emptied)
        if summary != TranscriptRetentionSummary() {
            log.info("""
                transcripts: \(summary.compressed, privacy: .public) compressed, \(summary.deleted, privacy: .public) deleted, \
                \(summary.postponed, privacy: .public) postponed, \(summary.failures, privacy: .public) failed, \
                \(summary.bytesFreed, privacy: .public) bytes freed
                """)
        }
        return summary
    }

    /// Runs a pass `firstAfter` from now and then every `interval`, until the task is cancelled.
    /// - Parameters:
    ///   - interval: defaults to an hour.
    ///   - firstAfter: defaults to five minutes, so the app's start is not slowed down.
    ///   - clock: the clock to wait on; tests pass a manual one.
    public func run<C: Clock>(every interval: C.Duration, firstAfter: C.Duration, clock: C) async {
        // The delays are the hourly cadence itself, not a poll for some state: cancellable, and
        // driven by the injected clock so tests do not wait.
        do {
            try await clock.sleep(for: firstAfter)
            while !Task.isCancelled {
                await runOnce()
                try await clock.sleep(for: interval)
            }
        } catch {}
    }

    /// ``run(every:firstAfter:clock:)`` hourly on the continuous clock, first after five minutes.
    public func run() async {
        await run(every: .seconds(3600), firstAfter: .seconds(300), clock: ContinuousClock())
    }

    private func compress(_ url: URL, into summary: inout TranscriptRetentionSummary) async {
        let manager = FileManager.default
        let archive = URL(fileURLWithPath: url.path + ".gz")
        let temporary = URL(fileURLWithPath: archive.path + ".tmp")
        guard let before = try? manager.attributesOfItem(atPath: url.path),
              let modified = before[.modificationDate] as? Date else {
            summary.failures += 1
            return
        }
        let originalSize = (before[.size] as? NSNumber)?.int64Value ?? 0
        let archiveSize = fileSize(archive)
        let archiveDate = (try? manager.attributesOfItem(atPath: archive.path))?[.modificationDate] as? Date
        // A pass cut between replacing the archive and removing the original leaves both with the
        // same date: the archive already holds it, and compressing again would duplicate it.
        if archiveDate == modified {
            try? manager.removeItem(at: url)
            summary.compressed += 1
            summary.bytesFreed += originalSize
            return
        }
        try? manager.removeItem(at: temporary)
        do {
            if manager.fileExists(atPath: archive.path) { try manager.copyItem(at: archive, to: temporary) }
        } catch {
            summary.failures += 1
            return
        }
        guard await compressor.append(url, to: temporary), await compressor.verify(temporary) else {
            try? manager.removeItem(at: temporary)
            summary.failures += 1
            return
        }
        guard let after = try? manager.attributesOfItem(atPath: url.path),
              after[.modificationDate] as? Date == modified,
              (after[.size] as? NSNumber)?.int64Value == originalSize else {
            try? manager.removeItem(at: temporary)
            summary.postponed += 1
            return
        }
        var attributes: [FileAttributeKey: Any] = [.modificationDate: modified]
        if let permissions = before[.posixPermissions] { attributes[.posixPermissions] = permissions }
        do {
            try manager.setAttributes(attributes, ofItemAtPath: temporary.path)
            guard rename(temporary.path, archive.path) == 0 else {
                try? manager.removeItem(at: temporary)
                summary.failures += 1
                return
            }
            // The AI may still write between the check and the rename: then the archive goes back
            // to what it was and the transcript waits for the next pass.
            let latest = try? manager.attributesOfItem(atPath: url.path)
            guard latest?[.modificationDate] as? Date == modified,
                  (latest?[.size] as? NSNumber)?.int64Value == originalSize else {
                restore(archive, size: archiveSize, date: archiveDate)
                summary.postponed += 1
                return
            }
            try manager.removeItem(at: url)
        } catch {
            summary.failures += 1
            return
        }
        summary.compressed += 1
        summary.bytesFreed += originalSize - (fileSize(archive) - archiveSize)
    }

    /// Puts an archive back as it was before a pass appended to it, or removes it if it is new.
    private nonisolated func restore(_ archive: URL, size: Int64, date: Date?) {
        guard let date else {
            try? FileManager.default.removeItem(at: archive)
            return
        }
        if let handle = try? FileHandle(forWritingTo: archive) {
            try? handle.truncate(atOffset: UInt64(size))
            try? handle.close()
        }
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: archive.path)
    }

    /// Every regular file under the roots, never following links. Synchronous: the directory
    /// enumerator cannot be iterated from an async body.
    private nonisolated func scan(reference: Date) -> [TranscriptEntry] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        var entries: [TranscriptEntry] = []
        for root in roots {
            let base = root.url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            guard let enumerator = FileManager.default.enumerator(at: root.url, includingPropertiesForKeys: keys) else { continue }
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      let modified = values.contentModificationDate else { continue }
                let components = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.pathComponents
                    + [url.lastPathComponent]
                guard components.starts(with: base), components.count > base.count else { continue }
                let relative = components.dropFirst(base.count).joined(separator: "/")
                entries.append(TranscriptEntry(path: root.name + "/" + relative, ageDays: reference.timeIntervalSince(modified) / 86_400))
            }
        }
        return entries
    }

    private func fileURL(for path: String) -> URL? {
        guard let slash = path.firstIndex(of: "/"),
              let root = roots.first(where: { $0.name == path[..<slash] }) else { return nil }
        let relative = path[path.index(after: slash)...]
        guard !relative.split(separator: "/").contains("..") else { return nil }
        return root.url.appendingPathComponent(String(relative))
    }

    private func removeEmptyFolders(_ folders: Set<URL>) {
        let rootPaths = Set(roots.map { $0.url.standardizedFileURL.path })
        for folder in folders {
            var current = folder.standardizedFileURL
            while !rootPaths.contains(current.path),
                  rootPaths.contains(where: { current.path.hasPrefix($0 + "/") }),
                  (try? FileManager.default.contentsOfDirectory(atPath: current.path))?.isEmpty == true {
                guard (try? FileManager.default.removeItem(at: current)) != nil else { break }
                current = current.deletingLastPathComponent()
            }
        }
    }

    private nonisolated func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
