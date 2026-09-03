import Foundation
@testable import UniConnectClaudeUpdate

/// An actor-isolated fake for every updater infrastructure boundary.
actor TestUpdaterHarness:
    ClaudeUpdateTargetProviding,
    ClaudeSessionControlling,
    ClaudeBinaryUpdating,
    ClaudeUpdateJournaling,
    ClaudeUpdateClock,
    ClaudeUpdateLogging
{
    private let providedTargets: [ClaudeUpdateTarget]
    private let versionBefore: ClaudeVersion
    private let versionAfter: ClaudeVersion
    private let commandResult: ClaudeUpdateCommandResult
    private let updateShouldFail: Bool
    private let restoreShouldFail: Bool
    private let verificationShouldMismatch: Bool
    private let pauseAtShell: Bool
    private let fixedDate: Date

    private var installedVersionValue: ClaudeVersion
    private var updateCount = 0
    private var restoredTargets: Set<ClaudeUpdateTargetID> = []
    private var events: [String] = []
    private var records: [String: ClaudeUpdateRecoveryRecord] = [:]
    private var logEntries: [ClaudeUpdateLogEntry] = []
    private var shellContinuation: CheckedContinuation<Void, Never>?
    private var shellReleaseRequested = false

    init(
        targets: [ClaudeUpdateTarget],
        versionBefore: ClaudeVersion,
        versionAfter: ClaudeVersion,
        commandResult: ClaudeUpdateCommandResult = ClaudeUpdateCommandResult(
            exitCode: 0,
            didTimeOut: false,
            standardOutput: "Claude Code updated successfully",
            standardError: ""
        ),
        updateShouldFail: Bool = false,
        restoreShouldFail: Bool = false,
        verificationShouldMismatch: Bool = false,
        pauseAtShell: Bool = false,
        fixedDate: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) {
        self.providedTargets = targets
        self.versionBefore = versionBefore
        self.versionAfter = versionAfter
        self.commandResult = commandResult
        self.updateShouldFail = updateShouldFail
        self.restoreShouldFail = restoreShouldFail
        self.verificationShouldMismatch = verificationShouldMismatch
        self.pauseAtShell = pauseAtShell
        self.fixedDate = fixedDate
        self.installedVersionValue = versionBefore
    }

    func targets(for scope: ClaudeUpdateScope) async throws -> [ClaudeUpdateTarget] {
        events.append("targets")
        return providedTargets
    }

    func inspect(_ target: ClaudeUpdateTarget) async throws -> ClaudeSessionInspection {
        events.append("inspect:\(target.id.rawValue)")
        guard let binding = target.binding else { throw TestUpdaterError.invalidProcess }
        let wasRestored = restoredTargets.contains(target.id)
        return ClaudeSessionInspection(
            isClaudeProcess: true,
            isIdle: true,
            processID: wasRestored ? 9_001 : 42,
            sessionID: verificationShouldMismatch && wasRestored ? UUID() : binding.sessionID,
            workingDirectory: binding.workingDirectory,
            executablePath: binding.executablePath,
            version: installedVersionValue
        )
    }

    func waitUntilReadyForExit(_ target: ClaudeUpdateTarget) async throws -> ClaudeSessionInspection {
        events.append("ready:\(target.id.rawValue)")
        guard let binding = target.binding else { throw TestUpdaterError.invalidProcess }
        return ClaudeSessionInspection(
            isClaudeProcess: true,
            isIdle: true,
            processID: 42,
            sessionID: binding.sessionID,
            workingDirectory: binding.workingDirectory,
            executablePath: binding.executablePath,
            version: installedVersionValue
        )
    }

    func requestCleanExit(
        _ target: ClaudeUpdateTarget,
        expectedProcessID: Int32
    ) async throws {
        guard expectedProcessID == 42 else { throw TestUpdaterError.invalidProcess }
        events.append("exit:\(target.id.rawValue)")
    }

    func waitForShellAfterExit(
        _ target: ClaudeUpdateTarget,
        exitedProcessID: Int32
    ) async throws {
        guard exitedProcessID == 42 else { throw TestUpdaterError.invalidProcess }
        events.append("shell:\(target.id.rawValue)")
        guard pauseAtShell, !shellReleaseRequested else { return }
        await withCheckedContinuation { continuation in
            shellContinuation = continuation
        }
    }

    func restore(_ target: ClaudeUpdateTarget) async throws {
        events.append("restore:\(target.id.rawValue)")
        if restoreShouldFail { throw TestUpdaterError.restoreFailed }
        restoredTargets.insert(target.id)
    }

    func installedVersion(
        on host: ClaudeUpdateHostIdentity,
        executablePath: String
    ) async throws -> ClaudeVersion {
        events.append("version:\(host.id):\(executablePath)")
        return installedVersionValue
    }

    func update(
        on host: ClaudeUpdateHostIdentity,
        executablePath: String
    ) async throws -> ClaudeUpdateCommandResult {
        events.append("update:\(host.id):\(executablePath)")
        updateCount += 1
        if updateShouldFail { throw TestUpdaterError.updateFailed }
        installedVersionValue = versionAfter
        return commandResult
    }

    func save(_ record: ClaudeUpdateRecoveryRecord) async throws {
        events.append("journal:\(record.stage.rawValue):\(record.target.id.rawValue)")
        records[record.id] = record
    }

    func remove(operationID: UUID, targetID: ClaudeUpdateTargetID) async throws {
        events.append("journal:remove:\(targetID.rawValue)")
        records.removeValue(forKey: "\(operationID.uuidString):\(targetID.rawValue)")
    }

    func pendingRecords() async throws -> [ClaudeUpdateRecoveryRecord] {
        records.values.sorted { $0.id < $1.id }
    }

    func now() async -> Date { fixedDate }

    func record(_ entry: ClaudeUpdateLogEntry) async {
        logEntries.append(entry)
    }

    func releaseShell() {
        shellReleaseRequested = true
        shellContinuation?.resume()
        shellContinuation = nil
    }

    func recordedEvents() -> [String] { events }

    func updateCallCount() -> Int { updateCount }

    func pendingRecordCount() -> Int { records.count }
}
