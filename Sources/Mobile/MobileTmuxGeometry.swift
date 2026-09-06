import Foundation

/// Measured tmux window and presentation dimensions, independent of the requested PTY size.
struct MobileTmuxGeometry: Equatable, Sendable {
    let columns: Int
    let rows: Int
    let statusRows: Int

    init?(fields: Substring) {
        let values = fields.split(separator: ":", omittingEmptySubsequences: false)
        guard values.count == 3,
              values[0].utf8.allSatisfy({ (48...57).contains($0) }),
              values[1].utf8.allSatisfy({ (48...57).contains($0) }),
              let columns = Int(values[0]), let rows = Int(values[1]) else { return nil }
        let statusRows: Int
        switch values[2] {
        case "off": statusRows = 0
        case "on": statusRows = 1
        case "2", "3", "4", "5": statusRows = Int(values[2])!
        default: return nil
        }
        guard (1...1000).contains(columns), (1...1000).contains(rows),
              rows + statusRows <= 1000 else { return nil }
        self.columns = columns
        self.rows = rows
        self.statusRows = statusRows
    }

    var jsonObject: [String: Any] {
        [
            "source_columns": columns, "source_rows": rows,
            "presentation_columns": columns, "presentation_rows": rows + statusRows,
        ]
    }
}
