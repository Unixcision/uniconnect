import Foundation

/// The history's search box.
///
/// Every word typed has to be found, in any order, in the text or in the window it was pasted
/// into, ignoring case, accents and punctuation: Whisper writes whatever accents it likes and
/// nobody types them back. Pieces of words count («relan» finds «relanzar»).
struct UniConnectDictationSearch: Equatable, Sendable {
    /// What was typed.
    let query: String

    /// The entries that match, in the history's own order (newest first).
    func filter(_ records: [UniConnectDictationRecord]) -> [UniConnectDictationRecord] {
        let words = Self.words(query)
        guard !words.isEmpty else { return records }
        return records.filter { Self.matches($0, words: words) }
    }

    /// Whether `record` matches the query.
    func matches(_ record: UniConnectDictationRecord) -> Bool {
        Self.matches(record, words: Self.words(query))
    }

    private static func matches(_ record: UniConnectDictationRecord, words: [String]) -> Bool {
        let haystack = fold([record.text, record.pastedInto].compactMap { $0 }.joined(separator: " "))
        return words.allSatisfy { haystack.contains($0) }
    }

    private static func words(_ text: String) -> [String] {
        fold(text).split(separator: " ").map(String.init)
    }

    /// Lower case, no accents, anything but letters and digits turned into one space.
    private static func fold(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es_ES"))
        var out = ""
        var lastWasSpace = true
        for character in folded {
            if character.isLetter || character.isNumber {
                out.append(character)
                lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
