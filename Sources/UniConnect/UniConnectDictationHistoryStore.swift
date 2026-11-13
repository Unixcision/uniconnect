import Foundation

/// «Dictado»'s history on disk: one `<id>.m4a` per recording and an index, `indice.json`, written
/// whole on every change (it holds a few hundred short entries at most), like the phone's.
///
/// The folder is private (0700) and so is every file in it (0600): it holds what was said. An
/// entry that was still being transcribed when the app quit comes back as
/// ``UniConnectDictationRecord/State/unread``, with its audio, so it can be read again. A
/// recording cut off by a crash (`grabando-*.m4a`, never finalized) cannot be played and is
/// removed when the history is first read.
actor UniConnectDictationHistoryStore {
    private let directory: URL
    private let retention: UniConnectDictationRetention
    private var cache: [UniConnectDictationRecord]?

    /// Prefix of the file the recorder writes into before the recording becomes an entry.
    nonisolated static let recordingPrefix = "grabando-"

    /// - Parameters:
    ///   - directory: The history folder; tests pass a temporary one.
    ///   - retention: Limits; the phone's by default.
    init(directory: URL, retention: UniConnectDictationRetention = UniConnectDictationRetention()) {
        self.directory = directory
        self.retention = retention
    }

    /// The folder that holds the audio.
    nonisolated var folder: URL { directory }

    /// Where the recorder writes a new recording; it becomes an entry with ``add(recordingAt:seconds:at:)``.
    nonisolated func newRecordingURL() -> URL {
        directory.appendingPathComponent("\(Self.recordingPrefix)\(UUID().uuidString.lowercased()).m4a", isDirectory: false)
    }

    /// The kept audio of `record`, if it still has any.
    nonisolated func audioURL(of record: UniConnectDictationRecord) -> URL? {
        record.audioFile.map { directory.appendingPathComponent($0, isDirectory: false) }
    }

    /// Creates the private folder if it is missing, and makes it private if it already existed.
    func prepareFolder() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    /// Every entry, newest first.
    func records() -> [UniConnectDictationRecord] {
        load()
    }

    /// Moves a finished recording into the history as a new entry being transcribed.
    ///
    /// - Parameters:
    ///   - source: The file the recorder wrote, inside ``folder``.
    ///   - seconds: Its length.
    ///   - date: When it stopped.
    /// - Returns: The new entry and the whole history.
    /// - Throws: When the file cannot be moved; the recording is then still at `source`.
    func add(
        recordingAt source: URL,
        seconds: Double,
        at date: Date
    ) throws -> (record: UniConnectDictationRecord, all: [UniConnectDictationRecord]) {
        try prepareFolder()
        let id = UUID().uuidString.lowercased()
        let name = "\(id).m4a"
        let destination = directory.appendingPathComponent(name, isDirectory: false)
        try FileManager.default.moveItem(at: source, to: destination)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let record = UniConnectDictationRecord(
            id: id,
            createdAt: date,
            text: nil,
            state: .transcribing,
            audioFile: name,
            audioBytes: Int64(size),
            seconds: seconds,
            pastedInto: nil
        )
        let all = change { [record] + $0 }
        return (all.first { $0.id == id } ?? record, all)
    }

    /// Stores what Whisper understood from entry `id`, also when it is read again.
    ///
    /// - Parameter seconds: The length Whisper measured, which replaces the recorder's estimate.
    func transcribed(id: String, text: String, seconds: Double?) -> [UniConnectDictationRecord] {
        change { records in
            records.map { record in
                guard record.id == id else { return record }
                var updated = record
                updated.text = text
                updated.state = .done
                if let seconds, seconds > 0 { updated.seconds = seconds }
                return updated
            }
        }
    }

    /// Marks entry `id` as read by no engine. Its audio stays, and so does an earlier text.
    func unread(id: String) -> [UniConnectDictationRecord] {
        change { records in
            records.map { record in
                guard record.id == id else { return record }
                var updated = record
                updated.state = record.text == nil ? .unread : .done
                return updated
            }
        }
    }

    /// Notes the window entry `id` was pasted into.
    func pasted(id: String, into name: String) -> [UniConnectDictationRecord] {
        change { records in
            records.map { record in
                guard record.id == id else { return record }
                var updated = record
                updated.pastedInto = name
                return updated
            }
        }
    }

    /// Removes these entries with their audio.
    func delete(ids: Set<String>) -> [UniConnectDictationRecord] {
        change { records in
            for record in records where ids.contains(record.id) {
                removeAudio(of: record)
            }
            return records.filter { !ids.contains($0.id) }
        }
    }

    /// Applies `update`, trims to the limits and writes the index.
    private func change(_ update: ([UniConnectDictationRecord]) -> [UniConnectDictationRecord]) -> [UniConnectDictationRecord] {
        var next = update(load())
        let trim = retention.trim(next)
        if !trim.isEmpty {
            for record in next where trim.dropRecords.contains(record.id) {
                removeAudio(of: record)
            }
            next = next
                .filter { !trim.dropRecords.contains($0.id) }
                .map { record in
                    guard trim.dropAudio.contains(record.id) else { return record }
                    removeAudio(of: record)
                    var updated = record
                    updated.audioFile = nil
                    return updated
                }
        }
        cache = next
        save(next)
        return next
    }

    private func removeAudio(of record: UniConnectDictationRecord) {
        guard let url = audioURL(of: record) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private var indexURL: URL {
        directory.appendingPathComponent("indice.json", isDirectory: false)
    }

    private func save(_ records: [UniConnectDictationRecord]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        do {
            try prepareFolder()
            try data.write(to: indexURL, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
        } catch {
            // The list on screen stays right; the next change writes the index again.
        }
    }

    private func load() -> [UniConnectDictationRecord] {
        if let cache { return cache }
        removeUnfinishedRecordings()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let data = try? Data(contentsOf: indexURL),
              let stored = try? decoder.decode([UniConnectDictationRecord].self, from: data) else {
            cache = []
            return []
        }
        let records = stored.map { record -> UniConnectDictationRecord in
            var updated = record
            // Nothing is transcribing at start-up: an entry left halfway was interrupted.
            if updated.state == .transcribing {
                updated.state = updated.text == nil ? .unread : .done
            }
            if let url = audioURL(of: record), !FileManager.default.fileExists(atPath: url.path) {
                updated.audioFile = nil
            }
            return updated
        }
        cache = records
        return records
    }

    private func removeUnfinishedRecordings() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix(Self.recordingPrefix) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name, isDirectory: false))
        }
    }
}
