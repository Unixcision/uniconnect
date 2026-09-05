/// A complete terminal frame and its revision in one host publisher lifetime.
public struct MobileTerminalRenderRecord: Equatable, Sendable {
    /// The complete screen captured for this revision.
    public let frame: MobileTerminalRenderGridFrame
    /// Monotonically increasing visual revision, independent of PTY byte counts.
    public let revision: UInt64

    init(frame: MobileTerminalRenderGridFrame, revision: UInt64) {
        self.frame = frame
        self.revision = revision
    }
}
