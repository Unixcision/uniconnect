import Foundation

/// What a pane shows, with its cursor: enough to tell an empty composer from a draft.
///
/// Plain text is not enough for every agent. Codex's composer reads `› Ask Codex to do anything`
/// both when it is empty (a dimmed placeholder) and when somebody typed exactly those words; only
/// the cursor column and the styling tell them apart.
public struct RelaunchPaneScreen: Sendable, Equatable {
    /// The pane's visible text (`capture-pane -p`).
    public let text: String
    /// The cursor's row in the visible pane, 0 at the top (`#{cursor_y}`).
    public let cursorRow: Int
    /// The cursor's column, 0 at the left (`#{cursor_x}`).
    public let cursorColumn: Int
    /// The same text with its styling escapes (`capture-pane -e -p`), when it could be read.
    public let styledText: String?

    /// Creates a screen reading.
    ///
    /// - Parameters:
    ///   - text: The visible text.
    ///   - cursorRow: The cursor row, 0 at the top.
    ///   - cursorColumn: The cursor column, 0 at the left.
    ///   - styledText: The text with styling escapes, if read.
    public init(text: String, cursorRow: Int, cursorColumn: Int, styledText: String? = nil) {
        self.text = text
        self.cursorRow = cursorRow
        self.cursorColumn = cursorColumn
        self.styledText = styledText
    }

    /// The visible lines, top first.
    public var lines: [String] {
        text.components(separatedBy: "\n")
    }

    /// The styled lines, top first; empty when the styled text was not read.
    public var styledLines: [String] {
        styledText?.components(separatedBy: "\n") ?? []
    }

    /// The line the cursor is on, or `nil` when the cursor is outside the text.
    public var cursorLine: String? {
        let all = lines
        return cursorRow >= 0 && cursorRow < all.count ? all[cursorRow] : nil
    }
}
