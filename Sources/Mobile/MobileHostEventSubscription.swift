import Foundation

/// What one `mobile.events.subscribe` stream asked for: its topics and, for terminal screens,
/// which windows.
///
/// A phone mirroring one window used to receive the full screen of every busy window. With
/// several AIs working, that flood overflowed the connection's queue within half a second and
/// the Mac closed it. A stream that names its windows only gets theirs.
struct MobileHostEventSubscription: Sendable, Equatable {
    /// Topics whose events are about one terminal, named by the `surface_id` of their payload.
    static let terminalTopics: Set<String> = ["terminal.render_grid", "terminal.updated"]

    let topics: Set<String>

    /// Upper-cased surface ids the phone watches; nil means every window, as phones that do not
    /// send `surface_ids` expect.
    let surfaceIDs: Set<String>?

    init(topics: Set<String>, surfaceIDs: Set<String>? = nil) {
        self.topics = topics
        self.surfaceIDs = surfaceIDs.map { Set($0.map { $0.uppercased() }) }
    }

    /// Whether this stream asks for terminal screens at all.
    var watchesTerminals: Bool { !topics.isDisjoint(with: Self.terminalTopics) }

    /// Whether an event of `topic` about `surfaceID` belongs to this stream.
    ///
    /// An event that is not about one window (a global `terminal.updated`) goes to every stream
    /// with the topic.
    func wants(topic: String, surfaceID: String?) -> Bool {
        guard topics.contains(topic) else { return false }
        guard Self.terminalTopics.contains(topic), let surfaceIDs, let surfaceID else { return true }
        return surfaceIDs.contains(surfaceID.uppercased())
    }
}
