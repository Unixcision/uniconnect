import CryptoKit
import Foundation

/// Keeps the sensitive source payload separate from the password-free preview model.
struct UniConnectPreparedImport {
    enum PreparationError: Error, Equatable {
        case invalidSelection
        case invalidSSHConnection(rowID: Int)
        case indeterminateSSHTarget(rowID: Int)
        case resolvedPlanBlocked
        case resolvedPlanChanged
        case invalidTmuxDeclaration(windowID: UniConnectImportPlan.WindowID)
    }

    private struct PendingSSHResolution {
        let sourceIndex: Int
        let rowID: Int
        let connectCommand: String
        let request: UniConnectSSHTargetResolutionRequest
    }

    let plan: UniConnectImportPlan
    let sourceDigest: String
    private let sourceDocument: UniConnectDocument
    private let sourceMap: UniConnectImportSourceMap
    private let sshCredentialRecordsByWorkspaceIndex: [Int: UniConnectSSHCredentialRecord]

    init(
        sourceDocument: UniConnectDocument,
        sourceMap: UniConnectImportSourceMap,
        sshCredentialRecordsByWorkspaceIndex: [Int: UniConnectSSHCredentialRecord] = [:],
        plan: UniConnectImportPlan
    ) {
        self.plan = plan
        self.sourceMap = sourceMap
        self.sshCredentialRecordsByWorkspaceIndex = sshCredentialRecordsByWorkspaceIndex
        // Keep the untouched declaration for deterministic re-planning. In particular,
        // duplicate agent bindings must be resolved identically after the live-state
        // preflight; re-planning the already-resolved payload would lose that conflict.
        self.sourceDocument = sourceDocument
        var digestDocument = sourceDocument
        for index in digestDocument.workspaces.indices {
            // A digest written to the journal must not become an offline oracle for a
            // weak password embedded in an sshpass declaration.
            digestDocument.workspaces[index].connect = nil
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = (try? encoder.encode(digestDocument)) ?? Data()
        self.sourceDigest = SHA256.hash(data: encoded)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func refreshedPlan(
        against currentDocument: UniConnectDocument,
        existingSSHCredentialRecordsByWorkspaceIndex: [Int: UniConnectSSHCredentialRecord]
    ) -> UniConnectImportPlan {
        UniConnectImportPlanner().plan(
            importing: sourceDocument,
            against: currentDocument,
            sourceMap: sourceMap,
            sshCredentialRecordsByWorkspaceIndex: sshCredentialRecordsByWorkspaceIndex,
            existingSSHCredentialRecordsByWorkspaceIndex:
                existingSSHCredentialRecordsByWorkspaceIndex
        )
    }

    func mutations(
        for selection: UniConnectImportSelection
    ) throws -> [UniConnectImportMutation] {
        let selected = selection.rowIDs
        let rows = plan.mutationRows.filter { selected.contains($0.id) }
        guard Set(rows.map(\.id)) == selected else {
            throw PreparationError.invalidSelection
        }
        return rows.sorted { $0.sourceIndex < $1.sourceIndex }.map { row in
            UniConnectImportMutation(
                rowID: row.id,
                outcome: row.outcome,
                existingWorkspaceIndex: row.existingWorkspaceIndex,
                existingWorkspaceID: row.existingWorkspaceID,
                workspace: row.workspace,
                windowRows: row.windowRows,
                sshCredentialRecord: nil
            )
        }
    }

    /// Resolves every selected SSH declaration once, then replans ownership using
    /// only the captured endpoints. No later phase consults `ssh_config` again.
    func resolvedMutations(
        for selection: UniConnectImportSelection,
        against currentDocument: UniConnectDocument,
        existingSSHCredentialRecordsByWorkspaceIndex: [Int: UniConnectSSHCredentialRecord],
        resolver: any UniConnectSSHTargetResolving
    ) async throws -> [UniConnectImportMutation] {
        let selectedRows = plan.mutationRows
            .filter { selection.rowIDs.contains($0.id) }
            .sorted { $0.sourceIndex < $1.sourceIndex }
        guard Set(selectedRows.map(\.id)) == selection.rowIDs else {
            throw PreparationError.invalidSelection
        }

        var resolvedRecords = sshCredentialRecordsByWorkspaceIndex
        var pending: [PendingSSHResolution] = []
        pending.reserveCapacity(selectedRows.count)

        for row in selectedRows where row.workspace.kind == .ssh {
            guard let rawConnect = row.workspace.connect,
                  let validated = UniConnectSSHConnectCommandValidator()
                    .validatedCommand(rawConnect),
                  let request = validated.targetResolutionRequest() else {
                throw PreparationError.invalidSSHConnection(rowID: row.id)
            }
            let connect = rawConnect.trimmingCharacters(in: .whitespacesAndNewlines)
            if let sourceRecord = resolvedRecords[row.sourceIndex] {
                let sourceConnect = sourceRecord.connectCommand
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard sourceConnect == connect else {
                    throw PreparationError.invalidSSHConnection(rowID: row.id)
                }
                if let target = sourceRecord.effectiveTarget {
                    resolvedRecords[row.sourceIndex] = UniConnectSSHCredentialRecord(
                        connectCommand: connect,
                        effectiveTarget: target
                    )
                    continue
                }
            }
            pending.append(.init(
                sourceIndex: row.sourceIndex,
                rowID: row.id,
                connectCommand: connect,
                request: request
            ))
        }

        if !pending.isEmpty {
            let outcomes = await resolver.resolve(pending.map(\.request))
            guard outcomes.count == pending.count else {
                throw PreparationError.indeterminateSSHTarget(rowID: pending[0].rowID)
            }
            for (item, outcome) in zip(pending, outcomes) {
                guard case .resolved(let target) = outcome else {
                    throw PreparationError.indeterminateSSHTarget(rowID: item.rowID)
                }
                resolvedRecords[item.sourceIndex] = UniConnectSSHCredentialRecord(
                    connectCommand: item.connectCommand,
                    effectiveTarget: target
                )
            }
        }

        let resolvedPlan = UniConnectImportPlanner().plan(
            importing: sourceDocument,
            against: currentDocument,
            sourceMap: sourceMap,
            sshCredentialRecordsByWorkspaceIndex: resolvedRecords,
            existingSSHCredentialRecordsByWorkspaceIndex:
                existingSSHCredentialRecordsByWorkspaceIndex
        )
        let resolvedRowsByID = Dictionary(uniqueKeysWithValues: resolvedPlan.rows.map {
            ($0.id, $0)
        })
        let originalRowsByID = Dictionary(uniqueKeysWithValues: plan.rows.map {
            ($0.id, $0)
        })
        for rowID in selection.rowIDs {
            guard let resolved = resolvedRowsByID[rowID], resolved.outcome.isMutation else {
                throw PreparationError.resolvedPlanBlocked
            }
            guard let original = originalRowsByID[rowID],
                  original.outcome == resolved.outcome,
                  original.existingWorkspaceIndex == resolved.existingWorkspaceIndex,
                  original.existingWorkspaceID == resolved.existingWorkspaceID else {
                throw PreparationError.resolvedPlanChanged
            }
        }
        let resolvedSelection: UniConnectImportSelection
        do {
            resolvedSelection = try UniConnectImportSelection(
                rowIDs: selection.rowIDs,
                plan: resolvedPlan
            )
        } catch {
            throw PreparationError.resolvedPlanBlocked
        }

        let rows = resolvedPlan.mutationRows.filter {
            resolvedSelection.rowIDs.contains($0.id)
        }
        return try rows.sorted { $0.sourceIndex < $1.sourceIndex }.map { row in
            let credentialRecord = resolvedRecords[row.sourceIndex]
            if row.workspace.kind == .ssh,
               credentialRecord?.effectiveTarget == nil {
                throw PreparationError.indeterminateSSHTarget(rowID: row.id)
            }
            return UniConnectImportMutation(
                rowID: row.id,
                outcome: row.outcome,
                existingWorkspaceIndex: row.existingWorkspaceIndex,
                existingWorkspaceID: row.existingWorkspaceID,
                workspace: row.workspace,
                windowRows: row.windowRows,
                sshCredentialRecord: credentialRecord
            )
        }
    }

    func existingTmuxRequirements(
        for mutations: [UniConnectImportMutation],
        ambientEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> [UniConnectExistingTmuxRequirement] {
        var requirements: [UniConnectExistingTmuxRequirement] = []
        for mutation in mutations where mutation.workspace.kind == .ssh {
            guard let record = mutation.sshCredentialRecord,
                  let target = record.effectiveTarget,
                  let validated = UniConnectSSHConnectCommandValidator()
                    .validatedCommand(record.connectCommand) else {
                throw PreparationError.invalidSSHConnection(rowID: mutation.rowID)
            }
            for windowRow in mutation.windowRows {
                guard let tmux = existingTmuxSession(in: windowRow.action) else { continue }
                guard let remoteCommand = UniConnectTmuxImportCommand.readOnlyExistenceCheck(session: tmux),
                      let validatedInvocation = validated.invocation(
                          injecting: Self.preflightOptions(
                              usesPasswordWrapper: validated.usesPasswordWrapper
                          ),
                          pinnedTo: target,
                          remoteCommand: remoteCommand,
                          ambientEnvironment: ambientEnvironment
                      ),
                      let invocation = UniConnectSSHProcessInvocation(
                          executable: validatedInvocation.executable,
                          arguments: validatedInvocation.arguments,
                          environment: validatedInvocation.environment
                      ) else {
                    throw PreparationError.invalidTmuxDeclaration(windowID: windowRow.id)
                }
                requirements.append(.init(
                    workspaceRowID: mutation.rowID,
                    windowID: windowRow.id,
                    session: tmux,
                    invocation: invocation
                ))
            }
        }
        return requirements
    }

    private static func preflightOptions(usesPasswordWrapper: Bool) -> [String] {
        [
            "-T",
            "-o", "ConnectTimeout=12",
            "-o", "ServerAliveInterval=20",
            "-o", "ServerAliveCountMax=2",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "ControlPersist=no",
            "-o", "ClearAllForwardings=yes",
            "-o", "ForwardAgent=no",
            "-o", "ForwardX11=no",
            "-o", "ForwardX11Trusted=no",
            "-o", "PermitLocalCommand=no",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", usesPasswordWrapper ? "BatchMode=no" : "BatchMode=yes",
            "-o", "StrictHostKeyChecking=accept-new",
        ]
    }

    private func existingTmuxSession(
        in action: UniConnectImportPlan.WindowAction
    ) -> String? {
        let destination: UniConnectImportPlan.WindowDestination
        switch action {
        case .create(let value), .update(let value):
            destination = value
        case .leaveUnchanged, .keepTerminalBecauseDuplicateAgent, .reject:
            return nil
        }
        guard case .attachExistingTmux(let session) = destination else { return nil }
        return session
    }
}
