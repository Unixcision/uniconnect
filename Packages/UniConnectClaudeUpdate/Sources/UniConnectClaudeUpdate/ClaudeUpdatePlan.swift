import Foundation

/// A validated, immutable update plan grouped into one command per host and installation identity.
public struct ClaudeUpdatePlan: Sendable, Hashable, Codable, Identifiable {
    /// The operation identifier used by progress and recovery records.
    public let id: UUID

    /// The requested selection scope.
    public let scope: ClaudeUpdateScope

    /// Validated host-and-installation groups in first-discovery order.
    public let hosts: [ClaudeUpdateHostPlan]

    /// Every planned target in deterministic host and target order.
    public var targets: [ClaudeUpdateTarget] { hosts.flatMap(\.targets) }

    /// Creates and validates a host-grouped update plan.
    ///
    /// Unresolved targets remain in the plan so orchestration can report them as skipped. Native
    /// and npm installations on the same host receive separate commands. Known duplicate UUIDs,
    /// duplicate panes, and executable-path conflicts fail before any mutation.
    ///
    /// - Parameters:
    ///   - id: A unique operation identifier.
    ///   - scope: The scope from which the targets were resolved.
    ///   - targets: Visible targets in deterministic discovery order.
    /// - Throws: ``ClaudeUpdatePlanError`` when starting the plan could alias or update the wrong
    ///   session, pane, host, or executable.
    public init(id: UUID = UUID(), scope: ClaudeUpdateScope, targets: [ClaudeUpdateTarget]) throws {
        guard !targets.isEmpty else {
            throw ClaudeUpdatePlanError.noTargets
        }

        try Self.validateScope(scope, targets: targets)
        try Self.validateUniqueTargets(targets)
        try Self.validateUniqueSessions(targets)
        try Self.validateUniquePanes(targets)

        var groups: [ClaudeUpdateHostPlan] = []
        var groupIndices: [ClaudeUpdateHostPlanID: Int] = [:]

        for target in targets {
            let installationID = target.binding?.installationID
            let groupID = ClaudeUpdateHostPlanID(
                host: target.host,
                installationID: installationID
            )
            if let index = groupIndices[groupID] {
                let current = groups[index]
                groups[index] = ClaudeUpdateHostPlan(
                    host: current.host,
                    targets: current.targets + [target],
                    installationID: current.installationID,
                    executablePath: current.executablePath
                )
            } else {
                groupIndices[groupID] = groups.count
                groups.append(
                    ClaudeUpdateHostPlan(
                        host: target.host,
                        targets: [target],
                        installationID: installationID,
                        executablePath: nil
                    )
                )
            }
        }

        self.id = id
        self.scope = scope
        self.hosts = try groups.map { group in
            let bindings = group.targets.compactMap(\.binding)
            let executablePaths = Set(bindings.map(\.executablePath))
            guard executablePaths.count <= 1 else {
                throw ClaudeUpdatePlanError.conflictingExecutablePaths(
                    hostID: group.host.id,
                    executablePaths: executablePaths.sorted()
                )
            }

            return ClaudeUpdateHostPlan(
                host: group.host,
                targets: group.targets,
                installationID: group.installationID,
                executablePath: executablePaths.first
            )
        }
    }

    private static func validateScope(_ scope: ClaudeUpdateScope, targets: [ClaudeUpdateTarget]) throws {
        switch scope {
        case let .selected(expected):
            guard targets.count == 1, targets[0].id == expected else {
                throw ClaudeUpdatePlanError.selectedTargetMismatch(expected: expected)
            }
        case let .box(expectedBoxID):
            if let mismatch = targets.first(where: { $0.boxID != expectedBoxID }) {
                throw ClaudeUpdatePlanError.boxMismatch(
                    expectedBoxID: expectedBoxID,
                    targetID: mismatch.id
                )
            }
        case .allOpen:
            break
        }
    }

    private static func validateUniqueTargets(_ targets: [ClaudeUpdateTarget]) throws {
        var seen: Set<ClaudeUpdateTargetID> = []
        for target in targets where !seen.insert(target.id).inserted {
            throw ClaudeUpdatePlanError.duplicateTargetID(target.id)
        }
    }

    private static func validateUniqueSessions(_ targets: [ClaudeUpdateTarget]) throws {
        var owners: [UUID: ClaudeUpdateTargetID] = [:]
        for target in targets {
            guard let sessionID = target.binding?.sessionID else { continue }
            if let owner = owners[sessionID] {
                throw ClaudeUpdatePlanError.duplicateSessionID(
                    sessionID,
                    first: owner,
                    second: target.id
                )
            }
            owners[sessionID] = target.id
        }
    }

    private static func validateUniquePanes(_ targets: [ClaudeUpdateTarget]) throws {
        var owners: [ClaudeUpdateHostIdentity: [ClaudeTmuxPaneIdentity: ClaudeUpdateTargetID]] = [:]
        for target in targets where target.host.kind == .remote {
            guard let pane = target.pane else { continue }
            if let owner = owners[target.host]?[pane] {
                throw ClaudeUpdatePlanError.duplicatePane(
                    hostID: target.host.id,
                    pane: pane,
                    first: owner,
                    second: target.id
                )
            }
            owners[target.host, default: [:]][pane] = target.id
        }
    }
}
