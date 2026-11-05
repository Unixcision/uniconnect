import Foundation
import os

/// The event streams of one mobile connection, by `stream_id`.
///
/// Render callbacks enqueue events synchronously, before a frame takes queue budget, so the
/// decision of whether this connection wants an event has to be readable there without an
/// actor hop. The connection actor changes the streams; everyone else only reads them.
final class MobileHostEventSubscriptions: Sendable {
    // Synchronous lock carve-out: read from non-async render callbacks before reserving queue
    // budget, where an actor hop would reorder frames. Short critical sections over a small map.
    private let streams = OSAllocatedUnfairLock(initialState: [String: MobileHostEventSubscription]())

    var isEmpty: Bool { streams.withLock { $0.isEmpty } }

    var count: Int { streams.withLock { $0.count } }

    func contains(streamID: String) -> Bool {
        streams.withLock { $0[streamID] != nil }
    }

    /// Whether any stream has `topic`, whatever windows it names.
    func isSubscribed(to topic: String) -> Bool {
        streams.withLock { $0.values.contains { $0.topics.contains(topic) } }
    }

    /// Whether some stream wants an event of `topic` about `surfaceID`.
    func wants(topic: String, surfaceID: String?) -> Bool {
        streams.withLock { $0.values.contains { $0.wants(topic: topic, surfaceID: surfaceID) } }
    }

    /// Sets or removes (nil) one stream and returns what it had before.
    @discardableResult
    func replace(streamID: String, with subscription: MobileHostEventSubscription?) -> MobileHostEventSubscription? {
        streams.withLock { streams in
            let previous = streams[streamID]
            streams[streamID] = subscription
            return previous
        }
    }

    /// Removes every stream and returns them.
    func removeAll() -> [MobileHostEventSubscription] {
        streams.withLock { streams in
            let previous = Array(streams.values)
            streams.removeAll()
            return previous
        }
    }
}
