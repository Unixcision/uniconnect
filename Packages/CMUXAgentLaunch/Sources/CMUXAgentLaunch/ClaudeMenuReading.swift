import Foundation

/// Claude Code's selection menus (folder trust, background work), read so an option is chosen by
/// its **text**, never by its position.
///
/// The folder-trust question of Claude 2.1.321 comes with «No, exit» first and preselected:
///
/// ```text
///  ❯ No, exit
///    Yes, I trust this folder
///  Enter to confirm · Esc to cancel
/// ```
///
/// Pressing Enter blindly kills the session that was just reopened. So the cursor (`❯`) is moved
/// line by line, the screen is read again, and Enter is pressed only when the marked line is the
/// wanted text.
public struct ClaudeMenuReading: Sendable, Equatable {
    /// The menu's option lines, top first, without the marker and leading numbering.
    public let options: [String]
    /// The index in ``options`` of the marked one.
    public let selected: Int

    /// Finds the menu that offers `option`.
    ///
    /// - Parameters:
    ///   - screen: The pane's plain text.
    ///   - option: The text of one option (`Yes, I trust this folder`).
    /// - Returns: `nil` when no menu with that option and exactly one marked line is on screen.
    public init?(screen: String, offering option: String) {
        let lines = screen.components(separatedBy: "\n")
        guard let target = lines.lastIndex(where: { $0.contains(option) }) else { return nil }
        // The menu is the block of lines around the wanted one with its same indentation, once
        // the marker is read as a space: `" ❯ No, exit"` and `"   Yes, I trust this folder"`.
        func indentation(_ line: String) -> Int? {
            let unmarked = line.replacingOccurrences(of: "❯", with: " ")
            guard unmarked.contains(where: { $0 != " " }) else { return nil }
            return unmarked.prefix(while: { $0 == " " }).count
        }
        guard let depth = indentation(lines[target]), depth > 0 else { return nil }
        var first = target
        while first > 0, indentation(lines[first - 1]) == depth { first -= 1 }
        var last = target
        while last + 1 < lines.count, indentation(lines[last + 1]) == depth { last += 1 }
        let block = Array(lines[first...last])
        let marked = block.indices.filter { block[$0].trimmingCharacters(in: .whitespaces).hasPrefix("❯") }
        guard marked.count == 1 else { return nil }
        options = block.map { line in
            var text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("❯") { text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
            if let dot = text.firstIndex(of: "."), text[..<dot].allSatisfy(\.isNumber), !text[..<dot].isEmpty {
                text = String(text[text.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
            }
            return text
        }
        selected = marked[0]
    }

    /// How many lines the marker must move to reach `option`: positive is down, negative is up.
    ///
    /// - Parameter option: The wanted option's text.
    /// - Returns: `nil` when no option line contains it, or more than one does.
    public func moves(to option: String) -> Int? {
        let matches = options.indices.filter { options[$0].contains(option) }
        guard matches.count == 1 else { return nil }
        return matches[0] - selected
    }

    /// Whether the marked option is `option`.
    public func isSelected(_ option: String) -> Bool {
        options.indices.contains(selected) && options[selected].contains(option)
    }
}
