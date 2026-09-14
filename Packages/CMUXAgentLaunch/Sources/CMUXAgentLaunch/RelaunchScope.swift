import Foundation

/// How much a relaunch request covers.
///
/// There is deliberately no "whole system": the client composes that by asking each machine for its
/// own ``machine`` scope. Pushing the fan-out up means a machine that never answered shows as a
/// machine that never answered, instead of disappearing inside somebody else's aggregate.
public enum RelaunchScope: Sendable, Hashable, Codable {
    /// One window.
    case window(id: String)
    /// Every window of one box.
    case workspace(id: String)
    /// Every window a UniConnect host holds — including its SSH boxes.
    ///
    /// A *host*, never an SSH destination: the windows of a server reached over SSH belong to the
    /// scope of the host that dials it.
    case machine(id: String)
}
