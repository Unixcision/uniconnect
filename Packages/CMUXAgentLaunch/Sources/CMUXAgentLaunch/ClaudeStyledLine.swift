import Foundation

/// One captured line as visible scalars, each one marked muted (dim or grey) or not.
struct ClaudeStyledLine: Sendable, Equatable {
    /// One visible scalar and how it was drawn.
    struct Cell: Sendable, Equatable {
        let scalar: Unicode.Scalar
        let muted: Bool
    }

    /// The visible scalars, left to right.
    let cells: [Cell]

    init(cells: [Cell]) {
        self.cells = cells
    }

    /// Parses SGR escapes (`ESC [ … m`); other escapes (OSC hyperlinks) are dropped.
    init(styled: String) {
        var cells: [Cell] = []
        var dim = false
        var grey = false
        var scalars = Array(styled.unicodeScalars)[...]
        while let scalar = scalars.popFirst() {
            if scalar == "\u{1B}" {
                guard let kind = scalars.first else { break }
                if kind == "[" {
                    scalars.removeFirst()
                    var parameters = ""
                    while let next = scalars.popFirst() {
                        if (0x40...0x7E).contains(next.value) {
                            if next == "m" { Self.apply(parameters, dim: &dim, grey: &grey) }
                            break
                        }
                        parameters.unicodeScalars.append(next)
                    }
                } else if kind == "]" {
                    // OSC: up to BEL or ST (ESC \).
                    scalars.removeFirst()
                    while let next = scalars.popFirst() {
                        if next == "\u{07}" { break }
                        if next == "\u{1B}", scalars.first == "\\" { scalars.removeFirst(); break }
                    }
                } else {
                    scalars.removeFirst()
                }
                continue
            }
            if scalar == "\r" { continue }
            cells.append(Cell(scalar: scalar, muted: dim || grey))
        }
        self.cells = cells
    }

    private static func apply(_ parameters: String, dim: inout Bool, grey: inout Bool) {
        let codes = parameters.isEmpty
            ? [0]
            : parameters.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        var index = 0
        while index < codes.count {
            switch codes[index] {
            case 0:
                dim = false
                grey = false
            case 2:
                dim = true
            case 22:
                dim = false
            case 90:
                grey = true
            case 30...37, 39, 91...97:
                grey = false
            case 38:
                if index + 2 < codes.count, codes[index + 1] == 5 {
                    let color = codes[index + 2]
                    grey = color == 8 || (232...254).contains(color)
                    index += 2
                } else if index + 4 < codes.count, codes[index + 1] == 2 {
                    let red = codes[index + 2], green = codes[index + 3], blue = codes[index + 4]
                    grey = red == green && green == blue && red > 0 && red < 200
                    index += 4
                }
            default:
                break
            }
            index += 1
        }
    }

    /// The visible text.
    var text: String {
        var result = ""
        result.unicodeScalars.append(contentsOf: cells.map(\.scalar))
        return result
    }

    /// A horizontal rule (`────`) or the top of the older composer box (`╭───`).
    var isRule: Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 10 else { return false }
        let body = trimmed.drop(while: { $0 == "╭" || $0 == "╰" })
        return body.allSatisfy { $0 == "─" || $0 == "╮" || $0 == "╯" }
    }

    /// A prompt line: `❯ …`, `> …`, or `│ > …` inside the older box.
    var isPrompt: Bool {
        let content = stripped(boxBorder: true).text
        return content.hasPrefix("❯") || content == ">" || content.hasPrefix("> ")
    }

    /// The text after the prompt marker and its space.
    var afterPrompt: ClaudeStyledLine {
        var rest = stripped(boxBorder: true).cells[...]
        if let first = rest.first, first.scalar == "❯" || first.scalar == ">" {
            rest.removeFirst()
            if rest.first?.scalar == " " { rest.removeFirst() }
        }
        return ClaudeStyledLine(cells: Array(rest))
    }

    /// A composer continuation line without its two-space hanging indent (and box borders).
    var continuation: ClaudeStyledLine {
        var rest = cells[...]
        if let border = rest.firstIndex(where: { $0.scalar != " " }), rest[border].scalar == "│" {
            var trimmed = Array(rest[rest.index(after: border)...])
            if let last = trimmed.lastIndex(where: { $0.scalar != " " }), trimmed[last].scalar == "│" {
                trimmed.remove(at: last)
            }
            rest = trimmed[...]
            if rest.first?.scalar == " " { rest.removeFirst() }
        }
        for _ in 0..<2 where rest.first?.scalar == " " { rest.removeFirst() }
        return ClaudeStyledLine(cells: Array(rest))
    }

    /// The line without leading spaces and, inside the older box, without its `│` borders.
    func stripped(boxBorder: Bool) -> ClaudeStyledLine {
        var rest = cells[...]
        while rest.first?.scalar == " " { rest.removeFirst() }
        if boxBorder, rest.first?.scalar == "│" {
            rest.removeFirst()
            var trimmed = Array(rest)
            if let last = trimmed.lastIndex(where: { $0.scalar != " " }), trimmed[last].scalar == "│" {
                trimmed.remove(at: last)
            }
            rest = trimmed[...]
            while rest.first?.scalar == " " { rest.removeFirst() }
        }
        return ClaudeStyledLine(cells: Array(rest))
    }

    /// Whether every visible character is muted, which is how a suggestion is drawn.
    var isMutedText: Bool {
        cells.allSatisfy { $0.scalar == " " || $0.muted }
    }
}
