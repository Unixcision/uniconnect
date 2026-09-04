import CryptoKit
import Foundation

/// Keeps the sensitive source payload separate from the password-free preview model.
struct UniConnectPreparedImport {
    enum PreparationError: Error, Equatable {
        case invalidSelection
        case invalidSSHConnection(rowID: Int)
        case invalidTmuxDeclaration(windowID: UniConnectImportPlan.WindowID)
    }

    let plan: UniConnectImportPlan
    let sourceDigest: String
    private let sourceDocument: UniConnectDocument
    private let sourceMap: UniConnectImportSourceMap

    init(
        sourceDocument: UniConnectDocument,
        sourceMap: UniConnectImportSourceMap,
        plan: UniConnectImportPlan
    ) {
        self.plan = plan
        self.sourceMap = sourceMap
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

    func refreshedPlan(against currentDocument: UniConnectDocument) -> UniConnectImportPlan {
        UniConnectImportPlanner().plan(
            importing: sourceDocument,
            against: currentDocument,
            sourceMap: sourceMap
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
                windowRows: row.windowRows
            )
        }
    }

    func existingTmuxRequirements(
        for selection: UniConnectImportSelection,
        ambientEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> [UniConnectExistingTmuxRequirement] {
        let selectedRows = plan.mutationRows.filter { selection.rowIDs.contains($0.id) }
        guard Set(selectedRows.map(\.id)) == selection.rowIDs else {
            throw PreparationError.invalidSelection
        }
        var requirements: [UniConnectExistingTmuxRequirement] = []
        for row in selectedRows where row.preview.kind == .ssh {
            guard let connect = row.workspace.connect,
                  let validated = UniConnectSSHConnectCommandValidator().validatedCommand(connect),
                  let session = validated.detectedSession() else {
                throw PreparationError.invalidSSHConnection(rowID: row.id)
            }
            for windowRow in row.windowRows {
                guard let tmux = existingTmuxSession(in: windowRow.action) else { continue }
                guard let remoteCommand = UniConnectTmuxImportCommand.readOnlyExistenceCheck(session: tmux),
                      let invocation = UniConnectSSHProcessInvocation(
                          session: session,
                          remoteCommand: remoteCommand,
                          ambientEnvironment: ambientEnvironment
                      ) else {
                    throw PreparationError.invalidTmuxDeclaration(windowID: windowRow.id)
                }
                requirements.append(.init(
                    workspaceRowID: row.id,
                    windowID: windowRow.id,
                    session: tmux,
                    invocation: invocation
                ))
            }
        }
        return requirements
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
