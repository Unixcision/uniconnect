import Foundation

/// The «· desconectado» mark an SSH window carries in its saved title while its ssh client is down.
///
/// The mark is live state stored inside the title, so it survives a save: every path that attaches
/// the window again has to take it off. Reconnect always did; restore did not, and a window that
/// came back attached kept saying «desconectado» until its next reconnect.
struct UniConnectDisconnectedTitle {
    /// The suffix appended now (the catalog text).
    let suffix: String
    /// Every suffix recognised when removing the mark, including spellings older builds saved.
    let knownSuffixes: [String]

    init(
        suffix: String = String(
            localized: "uniconnect.window.disconnectedSuffix",
            defaultValue: " · disconnected"
        )
    ) {
        self.suffix = suffix
        knownSuffixes = [suffix, " · desconectado", "· desconectado", " · desconectada", " · disconnected"]
            .filter { !$0.isEmpty }
    }

    /// `title` without any disconnected mark, repeated marks and the space before them included.
    func stripped(_ title: String) -> String {
        var current = title
        while let mark = knownSuffixes.first(where: { current.hasSuffix($0) }) {
            current = String(current.dropLast(mark.count))
            while current.last?.isWhitespace == true {
                current.removeLast()
            }
        }
        return current
    }

    /// `title` carrying exactly one disconnected mark.
    func marked(_ title: String) -> String {
        stripped(title) + suffix
    }

    /// The custom title a restored SSH window keeps.
    ///
    /// A window that restores attached drops the mark its previous run saved; if its ssh client
    /// dies again the mark comes back. A window that cannot attach keeps its saved title untouched.
    /// - Parameters:
    ///   - saved: The custom title in the session snapshot.
    ///   - attaches: Whether restore built a working ssh/tmux launcher for the window.
    /// - Returns: The title to apply, or `nil` when nothing remains.
    func restoredTitle(_ saved: String?, attaches: Bool) -> String? {
        guard attaches, let saved else { return saved }
        let clean = stripped(saved)
        return clean.isEmpty ? nil : clean
    }
}
