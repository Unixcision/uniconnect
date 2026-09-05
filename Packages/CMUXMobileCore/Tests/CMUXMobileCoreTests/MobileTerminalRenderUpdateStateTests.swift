import Testing
@testable import CMUXMobileCore

@Suite("Complete terminal publication")
struct MobileTerminalRenderUpdateStateTests {
    @Test func identicalFrameIsSuppressedButCursorOnlyChangeIsPublished() throws {
        var publisher = MobileTerminalRenderUpdateState()
        var frame = try MobileTerminalRenderGridFrame(
            surfaceID: "terminal-a", stateSeq: 7, columns: 80, rows: 24, rowSpans: []
        )
        #expect(publisher.nextRevision(forFullFrame: frame) == 1)
        #expect(publisher.nextRevision(forFullFrame: frame) == nil)
        frame.cursor = .init(row: 0, column: 3, visible: true, style: .block)
        #expect(publisher.nextRevision(forFullFrame: frame) == 2)
        #expect(frame.stateSeq == 7)
    }

    @Test func modesColorsAndAlternateScreenDoNotDependOnNewBytes() throws {
        var publisher = MobileTerminalRenderUpdateState()
        var frame = try MobileTerminalRenderGridFrame(
            surfaceID: "terminal-a", stateSeq: 0, columns: 80, rows: 24, rowSpans: []
        )
        #expect(publisher.nextRevision(forFullFrame: frame) == 1)
        frame.terminalBackground = "#081125"
        #expect(publisher.nextRevision(forFullFrame: frame) == 2)
        frame.activeScreen = .alternate
        #expect(publisher.nextRevision(forFullFrame: frame) == 3)
        frame.columns = 40
        #expect(publisher.nextRevision(forFullFrame: frame) == 4)
    }

    @Test func partialFramesNeverBecomeSharedBaselinesAndResetPreservesOrder() throws {
        var publisher = MobileTerminalRenderUpdateState()
        var frame = try MobileTerminalRenderGridFrame(
            surfaceID: "terminal-a", stateSeq: 0, columns: 80, rows: 24, full: false, rowSpans: []
        )
        #expect(publisher.nextRevision(forFullFrame: frame) == nil)
        #expect(publisher.count == 0)
        frame.full = true
        #expect(publisher.nextRevision(forFullFrame: frame) == 1)
        publisher.removeAll()
        #expect(publisher.nextRevision(forFullFrame: frame) == 2)
        publisher.remove(surfaceID: frame.surfaceID)
        #expect(publisher.count == 0)
    }

    @Test func replayDoesNotConsumeAnotherClientsLivePublication() throws {
        var publisher = MobileTerminalRenderUpdateState()
        var frame = try MobileTerminalRenderGridFrame(surfaceID: "terminal-a", stateSeq: 7, columns: 80, rows: 24, rowSpans: [])
        #expect(publisher.nextRevision(forFullFrame: frame) == 1)
        frame.cursor = .init(row: 0, column: 4, visible: true, style: .block)
        let snapshot = publisher.snapshotRecord(forFullFrame: frame)
        let replay = try #require(snapshot)
        #expect(replay.revision == 2)
        #expect(publisher.nextRevision(forFullFrame: frame) == replay.revision)
        #expect(publisher.nextRevision(forFullFrame: frame) == nil)
    }

    @Test func unchangedReplaySharesThePublishedRevisionWithoutExtraEvents() throws {
        var publisher = MobileTerminalRenderUpdateState()
        let frame = try MobileTerminalRenderGridFrame(surfaceID: "terminal-a", stateSeq: 7, columns: 80, rows: 24, rowSpans: [])
        #expect(publisher.nextRevision(forFullFrame: frame) == 1)
        #expect(publisher.snapshotRecord(forFullFrame: frame)?.revision == 1)
        #expect(publisher.snapshotRecord(forFullFrame: frame)?.revision == 1)
        #expect(publisher.nextRevision(forFullFrame: frame) == nil)
    }

    @Test func laterLiveFrameCannotBeRolledBackByDelayedReplayResponse() throws {
        var publisher = MobileTerminalRenderUpdateState()
        var frame = try MobileTerminalRenderGridFrame(surfaceID: "terminal-a", stateSeq: 7, columns: 80, rows: 24, rowSpans: [])
        let snapshot = publisher.snapshotRecord(forFullFrame: frame)
        let replay = try #require(snapshot)
        frame.cursor = .init(row: 0, column: 4, visible: true, style: .block)
        let nextRevision = publisher.nextRevision(forFullFrame: frame)
        let liveRevision = try #require(nextRevision)
        #expect(liveRevision > replay.revision)
        #expect(replay.frame.cursor == nil)
        #expect(publisher.snapshotRecord(forFullFrame: frame)?.revision == liveRevision)
    }
}
