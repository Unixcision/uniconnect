import Foundation

/// How big «Dictado»'s history may grow: the phone's limits, 200 dictations and 300 MiB of audio.
///
/// Audio is what weighs, so it goes first, oldest first, and the text of those entries stays.
/// Whole entries are removed only beyond the record limit.
struct UniConnectDictationRetention: Equatable, Sendable {
    /// What has to go to stay within the limits.
    struct Trim: Equatable, Sendable {
        /// Entries removed entirely, with their audio.
        let dropRecords: Set<String>
        /// Entries that keep their text and lose their audio.
        let dropAudio: Set<String>

        var isEmpty: Bool { dropRecords.isEmpty && dropAudio.isEmpty }
    }

    let maxRecords: Int
    let maxAudioBytes: Int64

    /// - Parameters:
    ///   - maxRecords: Entries kept; the phone keeps 200 too.
    ///   - maxAudioBytes: Audio kept; 300 MiB is about 20 hours at 32 kbit/s.
    init(maxRecords: Int = 200, maxAudioBytes: Int64 = 300 * 1_048_576) {
        self.maxRecords = maxRecords
        self.maxAudioBytes = maxAudioBytes
    }

    /// What to remove from `records`, newest first: the newest entries keep their audio while it
    /// fits, everything older loses it.
    func trim(_ records: [UniConnectDictationRecord]) -> Trim {
        let dropRecords = Set(records.dropFirst(maxRecords).map(\.id))
        var dropAudio = Set<String>()
        var used: Int64 = 0
        var full = false
        for record in records where !dropRecords.contains(record.id) && record.audioFile != nil {
            if !full && used + record.audioBytes <= maxAudioBytes {
                used += record.audioBytes
            } else {
                full = true
                dropAudio.insert(record.id)
            }
        }
        return Trim(dropRecords: dropRecords, dropAudio: dropAudio)
    }
}
