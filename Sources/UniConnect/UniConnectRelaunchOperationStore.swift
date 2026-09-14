import CMUXAgentLaunch
import Foundation

/// Remembers the plans handed out and the operations accepted, so a second `apply` recovers instead
/// of running again.
///
/// This is what makes a dropped connection survivable. The phone that asked to relaunch twenty-six
/// agents and lost signal halfway comes back to the same operation and reads how it went, rather
/// than closing them all a second time.
@MainActor
final class UniConnectRelaunchOperationStore {
    private struct Entry {
        let token: RelaunchToken
        let deviceID: String
        var operation: RelaunchOperation?
        var targets: [UniConnectRelaunchExecutor.Target]
    }

    private var entries: [UUID: Entry] = [:]
    private let clock: @Sendable () -> Date

    init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
    }

    /// Records a plan and returns its token.
    func issue(
        deviceID: String,
        verb: RelaunchVerb,
        targets: [UniConnectRelaunchExecutor.Target],
        lifetime: TimeInterval = RelaunchPlan.defaultLifetime
    ) -> RelaunchToken {
        let token = RelaunchToken(
            deviceID: deviceID,
            operationID: UUID(),
            verb: verb,
            targets: Set(targets.map(\.key)),
            expiresAt: clock().addingTimeInterval(lifetime)
        )
        entries[token.operationID] = Entry(token: token, deviceID: deviceID, operation: nil, targets: targets)
        return token
    }

    /// The token handed out for `operationID`, if it is still remembered.
    func token(for operationID: UUID) -> RelaunchToken? { entries[operationID]?.token }

    /// The targets a plan chose.
    func targets(for operationID: UUID) -> [UniConnectRelaunchExecutor.Target] {
        entries[operationID]?.targets ?? []
    }

    /// Operations already accepted, for the admission gate to recognise a repeat.
    var accepted: [UUID: RelaunchAdmissionGate.KnownOperation] {
        entries.compactMapValues { entry in
            entry.operation.map { _ in .init(deviceID: entry.deviceID) }
        }
    }

    /// Marks an operation as accepted and running, so a repeat recovers it.
    ///
    /// Written **before** anything is closed on purpose: an operation that exists only once it
    /// finishes is an operation a network cut can erase, and erasing it is what makes the retry
    /// close everything twice.
    func accept(operationID: UUID, verb: RelaunchVerb, targets: [RelaunchTargetKey]) {
        guard var entry = entries[operationID] else { return }
        entry.operation = RelaunchOperation(
            operationID: operationID,
            verb: verb,
            recovered: false,
            results: targets.map { .init(key: $0, state: .planned) }
        )
        entries[operationID] = entry
    }

    /// Replaces what is known about an operation as it progresses.
    func update(operationID: UUID, results: [RelaunchOperation.Result]) {
        guard var entry = entries[operationID], let previous = entry.operation else { return }
        entry.operation = RelaunchOperation(
            operationID: operationID,
            verb: previous.verb,
            recovered: previous.recovered,
            results: results
        )
        entries[operationID] = entry
    }

    /// What is known about an operation, marked as recovered when it is being read back.
    func operation(_ operationID: UUID, recovered: Bool) -> RelaunchOperation? {
        guard let operation = entries[operationID]?.operation else { return nil }
        guard recovered else { return operation }
        return RelaunchOperation(
            operationID: operation.operationID,
            verb: operation.verb,
            recovered: true,
            results: operation.results
        )
    }
}
