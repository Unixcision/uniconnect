import Foundation
import Testing
@testable import CMUXMobileCore

private func historyFixture(_ count: Int) throws -> MobileTerminalRenderGridFrame {
    try MobileTerminalRenderGridFrame(
        surfaceID: "fixture-terminal",
        stateSeq: UInt64.max,
        columns: 120,
        rows: 3,
        cursor: .init(row: 2, column: 119, visible: false, style: .bar, blinking: true),
        styles: [.init(id: 77, foreground: "#12abcd", background: "#031122", bold: true, inverse: true)],
        rowSpans: [.init(row: 1, column: 2, styleID: 77, text: "👩‍💻e\u{301}", cellWidth: 3)],
        modes: [.init(code: 2004, on: true), .init(code: 7, on: false)],
        terminalForeground: "#abcdef",
        terminalBackground: "#010203",
        terminalCursorColor: "#21fabc",
        scrollbackRows: count,
        scrollbackSpans: (0..<count).map {
            .init(row: $0, column: 0, styleID: 77, text: "界\($0)", cellWidth: 2 + String($0).count)
        }
    )
}

@Test func boundedHistoryKeepsFiveThousandRowsAndUnicodeViewportUnchanged() throws {
    let source = try historyFixture(5000)
    let result = try #require(source.boundedHistory())
    #expect(result.scrollbackRows == 5000)
    #expect(result.scrollbackSpans.count == 5000)
    #expect(result.scrollbackSpans.first?.row == 0)
    #expect(result.scrollbackSpans.last?.row == 4999)
    #expect(result.scrollbackSpans.map(\.text) == source.scrollbackSpans.map(\.text))
    #expect(result.scrollbackSpans.map(\.cellWidth) == source.scrollbackSpans.map(\.cellWidth))
    #expect(result.surfaceID == source.surfaceID)
    #expect(result.stateSeq == source.stateSeq)
    #expect(result.columns == source.columns && result.rows == source.rows)
    #expect(result.cursor == source.cursor)
    #expect(result.modes == source.modes)
    #expect(result.terminalForeground == source.terminalForeground)
    #expect(result.terminalBackground == source.terminalBackground)
    #expect(result.terminalCursorColor == source.terminalCursorColor)
    var visible = source.rowSpans[0]
    visible.styleID = 0
    #expect(result.rowSpans == [visible])
    var style = source.styles[0]
    style.id = 0
    #expect(result.styles == [style])
    #expect(try JSONDecoder().decode(MobileTerminalRenderGridFrame.self, from: JSONEncoder().encode(result)) == result)
}

@Test func boundedHistoryRowCapDropsOldestRowsAndKeepsBlankRows() throws {
    var source = try historyFixture(5002)
    source.scrollbackSpans.removeAll { $0.row == 5000 }
    let result = try #require(source.boundedHistory())
    #expect(result.scrollbackRows == 5000)
    #expect(result.scrollbackSpans.first?.text == "界2")
    #expect(result.scrollbackSpans.first?.row == 0)
    #expect(result.scrollbackSpans.last?.row == 4999)
    #expect(!result.scrollbackSpans.contains { $0.row == 4998 })
    #expect(result.scrollbackSpans.count == 4999)
}

@Test func boundedHistorySpanBudgetNeverKeepsPartialHistoryRows() throws {
    var source = try historyFixture(3)
    source.scrollbackSpans.append(.init(row: 2, column: 20, styleID: 77, text: "final", cellWidth: 5))
    let retained = try #require(source.boundedHistory(maximumSpans: 3))
    #expect(retained.scrollbackRows == 1)
    #expect(retained.scrollbackSpans.count == 2)
    #expect(retained.scrollbackSpans.allSatisfy { $0.row == 0 })
    #expect(retained.scrollbackSpans.map(\.text) == ["界2", "final"])
    let viewport = try #require(source.boundedHistory(maximumSpans: 2))
    #expect(viewport.scrollbackRows == 0)
    #expect(viewport.scrollbackSpans.isEmpty)
    #expect(viewport.rowSpans == retained.rowSpans)
}

@Test func boundedHistoryStyleBudgetRemovesUnreferencedStylesAndCompactsIDs() throws {
    var source = try historyFixture(3)
    source.styles = [.init(id: 9, foreground: "#ff0000"), .init(id: 31, foreground: "#0000ff")] + source.styles
    source.styles.append(.init(id: 1200, foreground: "#unused"))
    source.scrollbackSpans[0].styleID = 9
    source.scrollbackSpans[1].styleID = 31
    let result = try #require(source.boundedHistory(maximumStyles: 1))
    #expect(result.scrollbackRows == 1)
    #expect(result.scrollbackSpans[0].text == "界2")
    #expect(result.styles.count == 1 && result.styles[0].id == 0)
    #expect(result.styles[0].foreground == "#12abcd")
    #expect(result.styles[0].inverse)
    #expect(result.rowSpans[0].styleID == 0 && result.scrollbackSpans[0].styleID == 0)
}

@Test func boundedHistoryUTF8ByteBudgetKeepsLargestFittingSuffix() throws {
    let source = try historyFixture(20)
    let expected = try #require(source.boundedHistory(maximumRows: 2))
    let encoded = try JSONEncoder().encode(expected)
    let text = try #require(String(data: encoded, encoding: .utf8))
    #expect(encoded.count > text.count)
    let result = try #require(source.boundedHistory(maximumEncodedBytes: encoded.count))
    #expect(result == expected)
    #expect(try JSONEncoder().encode(result).count <= encoded.count)
}

@Test func boundedHistoryAlternateAndDeltaFramesNeverPublishHistory() throws {
    var source = try historyFixture(3)
    source.activeScreen = .alternate
    let alternate = try #require(source.boundedHistory(maximumSpans: 1))
    #expect(alternate.full && alternate.activeScreen == .alternate)
    #expect(alternate.scrollbackRows == 0 && alternate.scrollbackSpans.isEmpty)
    #expect(alternate.cursor == source.cursor && alternate.modes == source.modes)
    source.activeScreen = .primary
    source.full = false
    source.clearedRows = [0, 2]
    let delta = try #require(source.boundedHistory(maximumStyles: 1))
    #expect(!delta.full && delta.clearedRows == [0, 2])
    #expect(delta.scrollbackRows == 0 && delta.scrollbackSpans.isEmpty)
    #expect(delta.rowSpans == alternate.rowSpans)
}

@Test func boundedHistoryKeepsViewportWhenNoHistoryFitsAndRejectsOversizeViewport() throws {
    let source = try historyFixture(5)
    let viewport = try #require(source.boundedHistory(maximumRows: 0))
    let bytes = try JSONEncoder().encode(viewport).count
    #expect(source.boundedHistory(maximumEncodedBytes: bytes) == viewport)
    #expect(source.boundedHistory(maximumEncodedBytes: bytes - 1) == nil)
    #expect(source.boundedHistory(maximumSpans: 0) == nil)
    var twoStyles = source
    twoStyles.styles.append(.init(id: 90, foreground: "#aabbcc"))
    twoStyles.rowSpans.append(.init(row: 2, column: 0, styleID: 90, text: "otro"))
    #expect(twoStyles.boundedHistory(maximumStyles: 1) == nil)
}

@Test func boundedHistoryRejectsInvalidLimitsAndAllowsBlankViewport() throws {
    let source = try historyFixture(1)
    #expect(source.boundedHistory(maximumRows: -1) == nil)
    #expect(source.boundedHistory(maximumEncodedBytes: 0) == nil)
    #expect(source.boundedHistory(maximumSpans: -1) == nil)
    #expect(source.boundedHistory(maximumStyles: 0) == nil)
    var blank = source
    blank.rowSpans = []
    let result = try #require(blank.boundedHistory(maximumRows: 0, maximumSpans: 0))
    #expect(result.rowSpans.isEmpty && result.scrollbackSpans.isEmpty)
    #expect(result.styles == [.default])
}
