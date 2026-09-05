import Foundation

extension MobileTerminalRenderGridFrame {
    /// Returns a size-bounded snapshot while preserving the complete visible viewport.
    ///
    /// Only the oldest scrollback rows may be removed. Retained history is
    /// renumbered from zero and its referenced styles are compacted together
    /// with the viewport styles. Text, explicit cell widths, cursor, screen,
    /// modes and dynamic colors remain unchanged. Alternate-screen and delta
    /// frames never carry scrollback.
    ///
    /// The usual fitting frame requires one encoding. Oversized history uses
    /// a known-valid viewport-only fallback and a binary search for the largest
    /// fitting suffix, rather than encoding once per discarded row. Compact
    /// style IDs follow their original numeric order so removing history cannot
    /// increase a surviving ID's encoded width.
    ///
    /// ```swift
    /// let mobileFrame = snapshot.boundedHistory(maximumRows: 5000)
    /// ```
    ///
    /// - Parameters:
    ///   - maximumRows: Maximum history rows to retain; zero requests the viewport only.
    ///   - maximumEncodedBytes: Maximum UTF-8 JSON size, excluding the transport envelope.
    ///   - maximumSpans: Maximum combined viewport and history spans; zero permits blank frames.
    ///   - maximumStyles: Maximum referenced styles; must permit at least the default style.
    /// - Returns: A bounded frame, or `nil` for invalid limits, unresolved viewport
    ///   styles, or a viewport that cannot fit without dropping visible content.
    public func boundedHistory(
        maximumRows: Int = 5000,
        maximumEncodedBytes: Int = 8 * 1024 * 1024 - 4096,
        maximumSpans: Int = 16384,
        maximumStyles: Int = 1024
    ) -> Self? {
        guard maximumRows >= 0, maximumEncodedBytes > 0, maximumSpans >= 0,
              maximumStyles > 0, scrollbackRows >= 0,
              rowSpans.count <= maximumSpans else { return nil }

        var stylesByID: [Int: Style] = [:]
        for style in styles { stylesByID[style.id] = style }
        if stylesByID.isEmpty { stylesByID[0] = .default }
        let orderedStyleIDs = stylesByID.keys.sorted()
        let requestedRows = full && activeScreen == .primary ? min(maximumRows, scrollbackRows) : 0
        let encoder = JSONEncoder()

        func materialize(_ retainedRows: Int) -> Self? {
            let firstRow = scrollbackRows - retainedRows
            var history: [RowSpan] = []
            if retainedRows > 0 {
                for span in scrollbackSpans where span.row >= firstRow && span.row < scrollbackRows {
                    guard history.count < maximumSpans - rowSpans.count else { return nil }
                    var retained = span
                    retained.row -= firstRow
                    history.append(retained)
                }
            }
            let referencedIDs = Set(rowSpans.map(\.styleID)).union(history.map(\.styleID))
            guard referencedIDs.count <= maximumStyles else { return nil }
            var remappedIDs: [Int: Int] = [:]
            var retainedStyles: [Style] = []
            for identifier in orderedStyleIDs where referencedIDs.contains(identifier) {
                guard var style = stylesByID[identifier] else { return nil }
                remappedIDs[identifier] = retainedStyles.count
                style.id = retainedStyles.count
                retainedStyles.append(style)
            }
            guard remappedIDs.count == referencedIDs.count else { return nil }
            func remap(_ span: RowSpan) -> RowSpan {
                var result = span
                result.styleID = remappedIDs[span.styleID] ?? span.styleID
                return result
            }
            var candidate = self
            candidate.scrollbackRows = retainedRows
            candidate.scrollbackSpans = history.map(remap)
            candidate.rowSpans = rowSpans.map(remap)
            candidate.styles = retainedStyles.isEmpty ? [.default] : retainedStyles
            guard let data = try? encoder.encode(candidate), data.count <= maximumEncodedBytes else { return nil }
            return candidate
        }

        if let frame = materialize(requestedRows) { return frame }
        guard requestedRows > 0, var best = materialize(0) else { return nil }
        var lower = 0
        var upper = requestedRows
        while upper - lower > 1 {
            let retainedRows = lower + (upper - lower) / 2
            if let frame = materialize(retainedRows) {
                lower = retainedRows
                best = frame
            } else {
                upper = retainedRows
            }
        }
        return best
    }
}
