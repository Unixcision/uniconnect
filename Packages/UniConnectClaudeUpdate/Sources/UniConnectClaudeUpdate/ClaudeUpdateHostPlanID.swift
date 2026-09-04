/// A stable identity for one Claude installation plan on one host.
public struct ClaudeUpdateHostPlanID:
    RawRepresentable,
    Sendable,
    Hashable,
    Codable,
    CustomStringConvertible
{
    /// The length-delimited identifier used by collections and serialized results.
    public let rawValue: String

    /// Creates an unchecked identifier from an already serialized value.
    ///
    /// - Parameter rawValue: The serialized host-plan identity.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates an unambiguous identity from a host and optional installation identity.
    ///
    /// - Parameters:
    ///   - host: The machine or remote endpoint owning the installation.
    ///   - installationID: The non-secret installation identity, or `nil` for unresolved targets.
    public init(host: ClaudeUpdateHostIdentity, installationID: String?) {
        let hostID = host.id
        let installationComponent: String
        if let installationID {
            installationComponent = "known:\(installationID.utf8.count):\(installationID)"
        } else {
            installationComponent = "unresolved"
        }
        rawValue = "\(host.kind.rawValue):\(hostID.utf8.count):\(hostID):\(installationComponent)"
    }

    /// The serialized identifier.
    public var description: String { rawValue }
}
