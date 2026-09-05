import Foundation

/// Tracks complete terminal snapshots independently of the PTY byte sequence.
///
/// Byte positions do not identify cursor-only, color, mode, or viewport changes.
/// Every emitted frame is self-contained so clients never share a delta baseline.
/// Construct one value per host render publisher; resetting it starts a new stream.
public struct MobileTerminalRenderUpdateState: Sendable {
    private var frames: [String: MobileTerminalRenderRecord] = [:]
    private var publishedRevisions: [String: UInt64] = [:]
    private var revision: UInt64 = 0

    /// The number of terminal snapshots retained for change detection.
    public var count: Int { frames.count }

    /// Creates an empty publisher state with no global or filesystem dependencies.
    public init() {}

    /// Returns the revision of a complete frame that has not yet been published.
    ///
    /// Partial frames are rejected because they cannot establish a new client's
    /// screen. Revisions order events within one publisher lifetime, not across
    /// host restarts. Clients reset their revision tracking when reconnecting.
    ///
    /// - Parameter frame: A validated complete terminal snapshot.
    /// - Returns: Its strictly increasing publication revision, or `nil` when
    ///   this frame was already published or is partial.
    public mutating func nextRevision(forFullFrame frame: MobileTerminalRenderGridFrame) -> UInt64? {
        guard let record = snapshotRecord(forFullFrame: frame),
              publishedRevisions[frame.surfaceID] != record.revision else { return nil }
        publishedRevisions[frame.surfaceID] = record.revision
        return record.revision
    }

    /// Records a replay snapshot without consuming the next live publication.
    ///
    /// The host calls this at the same isolation boundary as screen capture.
    /// A later event may reach the transport before the replay response; clients
    /// keep the larger revision instead of discarding events by arrival order.
    ///
    /// - Parameter frame: A complete screen captured for a replay or live update.
    /// - Returns: The existing revision for an identical frame, a new revision
    ///   for a changed frame, or `nil` for a partial frame.
    public mutating func snapshotRecord(forFullFrame frame: MobileTerminalRenderGridFrame) -> MobileTerminalRenderRecord? {
        guard frame.full else { return nil }
        if let previous = frames[frame.surfaceID], previous.frame == frame { return previous }
        revision += 1
        let record = MobileTerminalRenderRecord(frame: frame, revision: revision)
        frames[frame.surfaceID] = record
        return record
    }

    /// Removes a vanished surface without disturbing other terminals' revisions.
    /// - Parameter surfaceID: The terminal identity to forget.
    public mutating func remove(surfaceID: String) {
        frames.removeValue(forKey: surfaceID)
        publishedRevisions.removeValue(forKey: surfaceID)
    }

    /// Clears cached screens while preserving revision ordering for connected clients.
    public mutating func removeAll() {
        frames.removeAll()
        publishedRevisions.removeAll()
    }
}
