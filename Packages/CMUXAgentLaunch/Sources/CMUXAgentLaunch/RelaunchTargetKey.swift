import Foundation

/// Identifies one relaunch target by *what it is*, never by who is looking at it.
///
/// The host that displays a pane is deliberately absent. The same remote pane can be visible from
/// the Mac and from the Linux box at once, and keying on the viewer makes each of them believe it
/// owns the pane: both relaunch it, and the reader's agent is restarted twice. Two independent
/// local registries cannot agree on "once" — only a key that belongs to the target itself can.
///
/// For a local box the destination is that machine; the shape of the key does not change.
///
/// ```swift
/// let key = RelaunchTargetKey(
///     destination: .ssh(user: "root", host: "185.237.235.117", port: 22),
///     tmuxServer: "uniconnect",
///     pane: "%2",
///     generation: 3
/// )
/// ```
public struct RelaunchTargetKey: Sendable, Hashable, Codable {
    /// Where the pane actually lives.
    public enum Destination: Sendable, Hashable, Codable {
        /// A box on this machine, named by its stable machine identifier.
        case local(machineID: String)
        /// A box on a server, named by the endpoint that would be dialled to reach it.
        case ssh(user: String, host: String, port: Int)

        var text: String {
            switch self {
            case let .local(machineID): "local:\(machineID)"
            case let .ssh(user, host, port): "ssh:\(user)@\(host):\(port)"
            }
        }
    }

    /// Where the pane lives.
    public let destination: Destination
    /// The tmux server (socket name) holding the session.
    public let tmuxServer: String
    /// The tmux pane identifier, as tmux spells it (`%13`).
    public let pane: String
    /// Bumped by the host every time the pane's occupant changes.
    ///
    /// Carried inside the key on purpose: a plan made for generation 7 must not act on generation 8,
    /// and comparing it is how that is caught.
    public let generation: Int

    public init(destination: Destination, tmuxServer: String, pane: String, generation: Int) {
        self.destination = destination
        self.tmuxServer = tmuxServer
        self.pane = pane
        self.generation = generation
    }

    /// The key as it travels in the protocol and appears in the fixtures.
    public var text: String {
        "\(destination.text)|tmux:\(tmuxServer)|pane:\(pane)|gen:\(generation)"
    }

    /// The same pane disregarding which occupant it holds.
    ///
    /// Two keys share this when they point at one pane across a generation change, which is what
    /// tells "the target moved on" apart from "a different target".
    public var paneIdentity: String {
        "\(destination.text)|tmux:\(tmuxServer)|pane:\(pane)"
    }

    /// Whether `other` is this very pane carrying a different occupant than the plan assumed.
    public func isSamePaneNewGeneration(as other: RelaunchTargetKey) -> Bool {
        paneIdentity == other.paneIdentity && generation != other.generation
    }
}
