import Foundation

/// Builds deterministic import outcomes without mutating workspaces, panels, or the vault.
struct UniConnectImportPlanner {
    private struct WindowRef: Hashable {
        let workspaceIndex: Int
        let windowIndex: Int

        var sourceKey: UniConnectImportSourceMap.WindowKey {
            .init(workspaceIndex: workspaceIndex, windowIndex: windowIndex)
        }
    }

    private typealias TmuxTarget = UniConnectSSHTargetKey

    private struct AgentTarget: Hashable {
        let kind: RestorableAgentKind
        let sessionID: String
    }

    private struct WindowMetadata {
        let index: Int
        let window: UniConnectDocument.Window
        let normalizedName: String
        let agentTargets: [AgentTarget]
        let claudeSessions: [UUID]
        let tmuxTarget: TmuxTarget?
        let validationIssues: [UniConnectImportPlan.Issue]
    }

    private struct WorkspaceMetadata {
        let index: Int
        let workspace: UniConnectDocument.Workspace
        let normalizedName: String
        let hostIdentity: String?
        let windows: [WindowMetadata]
        let validationIssues: [UniConnectImportPlan.Issue]

        var agentTargets: [AgentTarget] { windows.flatMap(\.agentTargets) }
        var claudeSessions: [UUID] { windows.flatMap(\.claudeSessions) }
        var tmuxTargets: [TmuxTarget] { windows.compactMap(\.tmuxTarget) }
    }

    private struct DuplicateAgentResolution {
        var effectiveDocument: UniConnectDocument
        var referencesByTarget: [AgentTarget: Set<WindowRef>]
        var fallbackByReference: [WindowRef: AgentTarget]
    }

    private struct CanonicalWindow: Equatable {
        let name: String?
        let tmux: String?
        let claudeSession: String?
        let cwd: String?
        let isPinned: Bool
        let localWindowID: UUID?
        let runtimeState: UniConnectLocalWindowRuntimeState?
        let localConversationKeys: [String]
        let latestLocalConversationKey: String?
    }

    private struct CanonicalWorkspaceProperties: Equatable {
        let name: String
        let kind: UniConnectWorkspaceKind
        let color: String?
        let group: String?
        let isPinned: Bool
        let cwd: String?
        let connect: String?
    }

    /// Plans an imported document against a snapshot of the current UniConnect document.
    func plan(
        importing document: UniConnectDocument,
        against existingDocument: UniConnectDocument,
        sourceMap: UniConnectImportSourceMap = .empty
    ) -> UniConnectImportPlan {
        let duplicateResolution = resolveDuplicateAgentBindings(in: document)
        let effectiveDocument = duplicateResolution.effectiveDocument
        let imported = effectiveDocument.workspaces.enumerated().map {
            metadata(for: $0.element, index: $0.offset, validate: true, sourceMap: sourceMap)
        }
        let existing = existingDocument.workspaces.enumerated().map {
            metadata(for: $0.element, index: $0.offset, validate: false, sourceMap: .empty)
        }
        var issuesByImportedIndex = imported.map(\.validationIssues)

        var importedWorkspaceIDs: [UUID: [Int]] = [:]
        var importedNames: [String: [Int]] = [:]
        var importedTmuxTargets: [TmuxTarget: [Int]] = [:]
        for item in imported {
            if let id = item.workspace.id {
                importedWorkspaceIDs[id, default: []].append(item.index)
            }
            if !item.normalizedName.isEmpty {
                importedNames[item.normalizedName, default: []].append(item.index)
            }
            for target in item.tmuxTargets {
                importedTmuxTargets[target, default: []].append(item.index)
            }
        }

        for (id, indexes) in importedWorkspaceIDs where indexes.count > 1 {
            for index in Set(indexes).sorted() {
                append(.duplicateWorkspaceIdentifier(id), to: &issuesByImportedIndex[index])
            }
        }
        for indexes in importedNames.values where indexes.count > 1 {
            for index in Set(indexes).sorted() {
                append(.duplicateWorkspaceName, to: &issuesByImportedIndex[index])
            }
        }
        for (target, indexes) in importedTmuxTargets where indexes.count > 1 {
            for index in Set(indexes).sorted() {
                append(
                    .duplicateTmuxTarget(
                        host: connectionIdentity(for: target),
                        session: target.tmuxSession
                    ),
                    to: &issuesByImportedIndex[index]
                )
            }
        }

        var existingWorkspaceIDs: [UUID: [Int]] = [:]
        var existingNames: [String: [Int]] = [:]
        var existingAgentTargets: [AgentTarget: [Int]] = [:]
        var existingTmuxTargets: [TmuxTarget: [Int]] = [:]
        for item in existing {
            if let id = item.workspace.id {
                existingWorkspaceIDs[id, default: []].append(item.index)
            }
            if !item.normalizedName.isEmpty {
                existingNames[item.normalizedName, default: []].append(item.index)
            }
            for target in item.agentTargets {
                existingAgentTargets[target, default: []].append(item.index)
            }
            for target in item.tmuxTargets {
                existingTmuxTargets[target, default: []].append(item.index)
            }
        }

        let rows = imported.map { item -> UniConnectImportPlan.Row in
            var issues = issuesByImportedIndex[item.index]
            if !issues.isEmpty {
                let outcome: UniConnectImportPlan.Outcome = item.validationIssues.isEmpty
                    ? .conflict
                    : .rejected
                return row(
                    for: item,
                    existing: nil,
                    outcome: outcome,
                    issues: issues,
                    sourceMap: sourceMap,
                    duplicateResolution: duplicateResolution
                )
            }

            var stableCandidates: Set<Int> = []
            var stableIdentityIsAmbiguous = false
            if let id = item.workspace.id {
                absorbStableMatches(
                    existingWorkspaceIDs[id] ?? [],
                    into: &stableCandidates,
                    isAmbiguous: &stableIdentityIsAmbiguous
                )
            }
            for target in item.agentTargets {
                absorbStableMatches(
                    existingAgentTargets[target] ?? [],
                    into: &stableCandidates,
                    isAmbiguous: &stableIdentityIsAmbiguous
                )
            }
            for target in item.tmuxTargets {
                absorbStableMatches(
                    existingTmuxTargets[target] ?? [],
                    into: &stableCandidates,
                    isAmbiguous: &stableIdentityIsAmbiguous
                )
            }

            if stableIdentityIsAmbiguous || stableCandidates.count > 1 {
                append(.ambiguousStableIdentity, to: &issues)
                return row(
                    for: item,
                    existing: nil,
                    outcome: .conflict,
                    issues: issues,
                    sourceMap: sourceMap,
                    duplicateResolution: duplicateResolution
                )
            }

            let nameMatches = existingNames[item.normalizedName] ?? []
            let existingIndex: Int?
            if let stableMatch = stableCandidates.first {
                if nameMatches.contains(where: { $0 != stableMatch }) {
                    append(.ambiguousName, to: &issues)
                    return row(
                        for: item,
                        existing: nil,
                        outcome: .conflict,
                        issues: issues,
                        sourceMap: sourceMap,
                        duplicateResolution: duplicateResolution
                    )
                }
                existingIndex = stableMatch
            } else {
                if nameMatches.count > 1 {
                    append(.ambiguousName, to: &issues)
                    return row(
                        for: item,
                        existing: nil,
                        outcome: .conflict,
                        issues: issues,
                        sourceMap: sourceMap,
                        duplicateResolution: duplicateResolution
                    )
                }
                existingIndex = nameMatches.first
            }

            guard let existingIndex else {
                return row(
                    for: item,
                    existing: nil,
                    outcome: .create,
                    issues: issues,
                    sourceMap: sourceMap,
                    duplicateResolution: duplicateResolution
                )
            }
            let existingItem = existing[existingIndex]
            guard item.workspace.kind == existingItem.workspace.kind else {
                append(.workspaceKindMismatch, to: &issues)
                return row(
                    for: item,
                    existing: existingItem,
                    outcome: .conflict,
                    issues: issues,
                    sourceMap: sourceMap,
                    duplicateResolution: duplicateResolution
                )
            }

            let connectionChanged = item.workspace.kind == .ssh
                && normalizedOptional(item.workspace.connect)
                    != normalizedOptional(existingItem.workspace.connect)
            let windowRows = makeWindowRows(
                imported: item,
                existing: existingItem,
                sourceMap: sourceMap,
                duplicateResolution: duplicateResolution,
                reconnectSSHWindows: connectionChanged
            )
            let unresolvedWindowConflicts = windowRows.filter {
                $0.outcome == .conflict && !$0.isResolvedConflict
            }
            if !unresolvedWindowConflicts.isEmpty {
                for issue in unresolvedWindowConflicts.flatMap(\.issues) {
                    append(issue, to: &issues)
                }
                return row(
                    for: item,
                    existing: existingItem,
                    outcome: .conflict,
                    issues: issues,
                    sourceMap: sourceMap,
                    duplicateResolution: duplicateResolution,
                    precomputedWindowRows: windowRows
                )
            }
            let metadataChanged = canonicalProperties(item.workspace)
                != canonicalProperties(existingItem.workspace)
            let windowsChanged = windowRows.contains(where: \.requiresMutation)
            let outcome: UniConnectImportPlan.Outcome = metadataChanged || windowsChanged ? .update : .unchanged
            return row(
                for: item,
                existing: existingItem,
                outcome: outcome,
                issues: issues,
                sourceMap: sourceMap,
                duplicateResolution: duplicateResolution,
                precomputedWindowRows: windowRows
            )
        }

        var documentIssues: [UniConnectImportPlan.Issue] = []
        appendSourceDiagnostics(sourceMap.documentDiagnostics, to: &documentIssues)
        return UniConnectImportPlan(
            rows: rows,
            documentIssues: sorted(documentIssues)
        )
    }

    /// Plans a detailed Markdown result while retaining line-level diagnostics.
    func plan(
        importing parsed: UniConnectMarkdownParseResult,
        against existingDocument: UniConnectDocument
    ) -> UniConnectImportPlan {
        plan(
            importing: parsed.document,
            against: existingDocument,
            sourceMap: parsed.sourceMap
        )
    }

    /// Prepares a sensitive import payload while exposing only its safe preview plan to UI.
    func prepare(
        importing document: UniConnectDocument,
        against existingDocument: UniConnectDocument,
        sourceMap: UniConnectImportSourceMap = .empty
    ) -> UniConnectPreparedImport {
        let plan = plan(
            importing: document,
            against: existingDocument,
            sourceMap: sourceMap
        )
        return UniConnectPreparedImport(
            sourceDocument: document,
            sourceMap: sourceMap,
            plan: plan
        )
    }

    /// Prepares a parsed Markdown import with all source diagnostics attached.
    func prepare(
        importing parsed: UniConnectMarkdownParseResult,
        against existingDocument: UniConnectDocument
    ) -> UniConnectPreparedImport {
        prepare(
            importing: parsed.document,
            against: existingDocument,
            sourceMap: parsed.sourceMap
        )
    }

    private func metadata(
        for workspace: UniConnectDocument.Workspace,
        index: Int,
        validate: Bool,
        sourceMap: UniConnectImportSourceMap
    ) -> WorkspaceMetadata {
        var issues: [UniConnectImportPlan.Issue] = []
        let name = normalizedName(workspace.name)
        if validate, name.isEmpty {
            append(.emptyWorkspaceName, to: &issues)
        }
        let group = normalizedOptional(workspace.group)
        if validate, workspace.group != nil, group == nil {
            append(.emptyGroupName, to: &issues)
        }
        if validate, workspace.isPinned == true, group != nil {
            append(.pinnedWorkspaceHasGroup, to: &issues)
        }
        if validate {
            appendSourceDiagnostics(sourceMap.diagnosticsByWorkspace[index] ?? [], to: &issues)
        }

        let connect = normalizedOptional(workspace.connect)
        let hostIdentity: String?
        switch workspace.kind {
        case .local:
            hostIdentity = nil
            if validate, connect != nil {
                append(.unexpectedSSHConnection, to: &issues)
            }
            if validate,
               UniConnectLocalWindowRecord.validatedBoxRoot(workspace.cwd ?? "~") == nil {
                append(.invalidLocalWorkingDirectory, to: &issues)
            }
            if validate, workspace.windows.isEmpty {
                append(.localWorkspaceMissingWindow, to: &issues)
            }
        case .ssh:
            if let connect {
                if validate, UniConnectSSH.validateConnectCommand(connect) != nil {
                    append(.invalidSSHConnection, to: &issues)
                }
                hostIdentity = connectionIdentity(for: connect)
            } else {
                hostIdentity = nil
                if validate { append(.missingSSHConnection, to: &issues) }
            }
        }

        let windows = workspace.windows.enumerated().map { windowIndex, window in
            windowMetadata(
                for: window,
                windowIndex: windowIndex,
                workspaceIndex: index,
                workspaceKind: workspace.kind,
                localBoxRoot: workspace.kind == .local
                    ? UniConnectLocalWindowRecord.validatedBoxRoot(workspace.cwd ?? "~")
                    : nil,
                sshSession: connect.flatMap(detectedSSHSession(for:)),
                validate: validate,
                sourceMap: sourceMap
            )
        }
        if validate {
            for window in windows {
                for issue in window.validationIssues { append(issue, to: &issues) }
            }
        }

        return WorkspaceMetadata(
            index: index,
            workspace: workspace,
            normalizedName: name,
            hostIdentity: hostIdentity,
            windows: windows,
            validationIssues: issues
        )
    }

    private func windowMetadata(
        for window: UniConnectDocument.Window,
        windowIndex: Int,
        workspaceIndex: Int,
        workspaceKind: UniConnectWorkspaceKind,
        localBoxRoot: String?,
        sshSession: DetectedSSHSession?,
        validate: Bool,
        sourceMap: UniConnectImportSourceMap
    ) -> WindowMetadata {
        var issues: [UniConnectImportPlan.Issue] = []
        let tmux = normalizedOptional(window.tmux)
        var agentTargets = localAgentTargets(in: window)
        var claudeSessions: [UUID] = []
        for target in agentTargets where target.kind == .claude {
            if let uuid = UUID(uuidString: target.sessionID) {
                if !claudeSessions.contains(uuid) { claudeSessions.append(uuid) }
            } else if validate {
                append(.invalidClaudeSession, to: &issues)
            }
        }
        agentTargets = unique(agentTargets)

        let tmuxTarget: TmuxTarget?
        switch workspaceKind {
        case .local:
            tmuxTarget = nil
            if validate, tmux != nil { append(.localWindowHasTmux, to: &issues) }
            if validate {
                guard let localBoxRoot else {
                    append(.invalidLocalWorkingDirectory, to: &issues)
                    break
                }
                let declaredWorkingDirectories = [
                    window.cwd,
                    window.localWindow?.workingDirectory,
                ].compactMap { $0 }
                let validatedWorkingDirectories = declaredWorkingDirectories.compactMap {
                    UniConnectLocalWindowRecord.validatedWorkingDirectory(
                        $0,
                        within: localBoxRoot
                    )
                }
                if validatedWorkingDirectories.count != declaredWorkingDirectories.count
                    || Set(validatedWorkingDirectories).count > 1 {
                    // `cwd` is the compatibility field and `localWindow.workingDirectory`
                    // is the durable source of truth. Accepting two different values would
                    // make preview/fingerprints disagree with the path used during apply.
                    append(.invalidLocalWorkingDirectory, to: &issues)
                }
                if let recordRoot = window.localWindow?.boxRoot,
                   UniConnectLocalWindowRecord.validatedBoxRoot(recordRoot) != localBoxRoot {
                    append(.invalidLocalWorkingDirectory, to: &issues)
                }
            }
        case .ssh:
            if validate, !agentTargets.isEmpty { append(.sshWindowHasClaudeSession, to: &issues) }
            guard let tmux else {
                if validate { append(.sshWindowMissingTmux, to: &issues) }
                tmuxTarget = nil
                break
            }
            guard isValidTmuxSession(tmux) else {
                if validate { append(.invalidTmuxSession, to: &issues) }
                tmuxTarget = nil
                break
            }
            tmuxTarget = sshSession.flatMap {
                TmuxTarget(session: $0, tmuxSession: tmux)
            }
        }

        if validate {
            let key = UniConnectImportSourceMap.WindowKey(
                workspaceIndex: workspaceIndex,
                windowIndex: windowIndex
            )
            appendSourceDiagnostics(sourceMap.diagnosticsByWindow[key] ?? [], to: &issues)
        }
        return WindowMetadata(
            index: windowIndex,
            window: window,
            normalizedName: normalizedName(window.name ?? ""),
            agentTargets: agentTargets,
            claudeSessions: claudeSessions,
            tmuxTarget: tmuxTarget,
            validationIssues: issues
        )
    }

    private func row(
        for imported: WorkspaceMetadata,
        existing: WorkspaceMetadata?,
        outcome: UniConnectImportPlan.Outcome,
        issues: [UniConnectImportPlan.Issue],
        sourceMap: UniConnectImportSourceMap,
        duplicateResolution: DuplicateAgentResolution,
        precomputedWindowRows: [UniConnectImportPlan.WindowRow]? = nil
    ) -> UniConnectImportPlan.Row {
        let windowRows = precomputedWindowRows ?? makeWindowRows(
            imported: imported,
            existing: existing,
            sourceMap: sourceMap,
            duplicateResolution: duplicateResolution
        )
        let mutationWorkspace = workspacePreservingExistingLocalHistory(
            imported: imported.workspace,
            existing: existing?.workspace,
            windowRows: windowRows
        )
        return UniConnectImportPlan.Row(
            sourceIndex: imported.index,
            workspace: mutationWorkspace,
            preview: workspacePreview(for: imported),
            existingWorkspaceIndex: existing?.index,
            existingWorkspaceID: existing?.workspace.id,
            outcome: outcome,
            issues: issues.sorted { issueSortKey($0) < issueSortKey($1) },
            windowRows: windowRows,
            sourceLocation: sourceMap.workspaceLocations[imported.index]
        )
    }

    /// CONNECT updates are additive for local conversation history. A legacy or
    /// partial document may change a title/cwd without knowing conversations that
    /// were discovered after it was exported; those local-only links must survive.
    private func workspacePreservingExistingLocalHistory(
        imported: UniConnectDocument.Workspace,
        existing: UniConnectDocument.Workspace?,
        windowRows: [UniConnectImportPlan.WindowRow]
    ) -> UniConnectDocument.Workspace {
        guard imported.kind == .local,
              let existing,
              let boxRoot = UniConnectLocalWindowRecord.validatedBoxRoot(imported.cwd ?? "~") else {
            return imported
        }
        var mergedWorkspace = imported
        for importedIndex in mergedWorkspace.windows.indices {
            guard windowRows.indices.contains(importedIndex),
                  let existingIndex = windowRows[importedIndex].existingWindowIndex,
                  existing.windows.indices.contains(existingIndex),
                  let existingRecord = existing.windows[existingIndex].localWindow else {
                continue
            }
            var importedWindow = mergedWorkspace.windows[importedIndex]
            let workingDirectory = [
                importedWindow.cwd,
                importedWindow.localWindow?.workingDirectory,
                existingRecord.workingDirectory,
                boxRoot,
            ].compactMap { candidate in
                candidate.flatMap {
                    UniConnectLocalWindowRecord.validatedWorkingDirectory($0, within: boxRoot)
                }
            }.first ?? boxRoot

            var mergedRecord = existingRecord
            if let importedRecord = importedWindow.localWindow {
                _ = mergedRecord.mergeImportedStatePreservingHistory(
                    importedRecord,
                    at: max(existingRecord.updatedAt, importedRecord.updatedAt)
                )
            } else if let claudeSession = normalizedOptional(importedWindow.claudeSession) {
                let legacyRecord = UniConnectLocalWindowRecord.migratingLegacy(
                    id: existingRecord.id,
                    visibleName: importedWindow.name,
                    boxRoot: boxRoot,
                    workingDirectory: workingDirectory,
                    agent: nil,
                    claudeSession: claudeSession,
                    wasAgentRunning: true,
                    timestamp: existingRecord.updatedAt
                )
                _ = mergedRecord.mergeImportedStatePreservingHistory(
                    legacyRecord,
                    at: existingRecord.updatedAt
                )
            }
            _ = mergedRecord.reconcileIdentity(
                visibleName: importedWindow.name,
                boxRoot: boxRoot,
                workingDirectory: workingDirectory,
                at: mergedRecord.updatedAt
            )
            importedWindow.cwd = mergedRecord.workingDirectory
            importedWindow.localWindow = mergedRecord
            importedWindow.claudeSession = mergedRecord.legacyClaudeSession
            mergedWorkspace.windows[importedIndex] = importedWindow
        }
        return mergedWorkspace
    }

    private func makeWindowRows(
        imported: WorkspaceMetadata,
        existing: WorkspaceMetadata?,
        sourceMap: UniConnectImportSourceMap,
        duplicateResolution: DuplicateAgentResolution,
        reconnectSSHWindows: Bool = false
    ) -> [UniConnectImportPlan.WindowRow] {
        imported.windows.map { window in
            let reference = WindowRef(workspaceIndex: imported.index, windowIndex: window.index)
            let sourceKey = reference.sourceKey
            var issues = window.validationIssues
            let duplicateTargets = duplicateResolution.referencesByTarget.compactMap { target, references in
                references.contains(reference) ? target : nil
            }.sorted(by: agentTargetSort)
            for target in duplicateTargets {
                if target.kind == .claude, let id = UUID(uuidString: target.sessionID) {
                    append(.duplicateClaudeSession(id), to: &issues)
                } else {
                    append(
                        .duplicateAgentSession(kind: target.kind, sessionID: target.sessionID),
                        to: &issues
                    )
                }
            }

            let name = normalizedOptional(window.window.name)
                ?? normalizedOptional(window.window.tmux)
                ?? String(localized: "uniconnect.import.window.unnamed", defaultValue: "Unnamed window")
            let declaredPolicy = resolvedTmuxPolicy(sourceMap.tmuxPolicies[sourceKey])
            // An endpoint edit migrates an already-owned tmux window. It must prove
            // that the session exists at the new endpoint and may never create it.
            let policy = reconnectSSHWindows && imported.workspace.kind == .ssh
                ? .attachExisting
                : declaredPolicy
            let location = sourceMap.windowLocations[sourceKey]

            if !window.validationIssues.isEmpty {
                return .init(
                    id: .init(workspaceIndex: imported.index, windowIndex: window.index),
                    name: name,
                    outcome: .rejected,
                    action: .reject,
                    existingWindowIndex: nil,
                    issues: sorted(issues),
                    sourceLocation: location,
                    tmuxPolicy: policy
                )
            }
            if let duplicate = duplicateResolution.fallbackByReference[reference] {
                let mutation: UniConnectImportPlan.Outcome
                var existingWindowIndex: Int? = nil
                if let existing {
                    let matches = matchingExistingWindowIndexes(for: window, in: existing)
                    if matches.count > 1 {
                        append(.ambiguousStableIdentity, to: &issues)
                        return .init(
                            id: .init(workspaceIndex: imported.index, windowIndex: window.index),
                            name: name,
                            outcome: .conflict,
                            action: .reject,
                            existingWindowIndex: nil,
                            issues: sorted(issues),
                            sourceLocation: location,
                            tmuxPolicy: policy
                        )
                    } else if let match = matches.first {
                        existingWindowIndex = match
                        if imported.workspace.kind == .local,
                           !existing.windows[match].agentTargets.isEmpty,
                           existing.windows[match].agentTargets != window.agentTargets {
                            append(.activeAgentWouldBeReplaced, to: &issues)
                            return .init(
                                id: .init(workspaceIndex: imported.index, windowIndex: window.index),
                                name: name,
                                outcome: .conflict,
                                action: .reject,
                                existingWindowIndex: match,
                                issues: sorted(issues),
                                sourceLocation: location,
                                tmuxPolicy: policy
                            )
                        }
                        mutation = canonicalWindow(window.window, workspace: imported.workspace)
                            == canonicalWindow(existing.windows[match].window, workspace: existing.workspace)
                            ? .unchanged
                            : .update
                    } else {
                        mutation = .create
                    }
                } else {
                    mutation = .create
                }
                return .init(
                    id: .init(workspaceIndex: imported.index, windowIndex: window.index),
                    name: name,
                    outcome: .conflict,
                    action: .keepTerminalBecauseDuplicateAgent(
                        kind: duplicate.kind,
                        sessionID: duplicate.sessionID,
                        mutation: mutation
                    ),
                    existingWindowIndex: existingWindowIndex,
                    issues: sorted(issues),
                    sourceLocation: location,
                    tmuxPolicy: policy
                )
            }

            let destination = destination(for: window.window, workspaceKind: imported.workspace.kind, policy: policy)
            guard let existing else {
                return .init(
                    id: .init(workspaceIndex: imported.index, windowIndex: window.index),
                    name: name,
                    outcome: .create,
                    action: .create(destination),
                    existingWindowIndex: nil,
                    issues: sorted(issues),
                    sourceLocation: location,
                    tmuxPolicy: policy
                )
            }

            let matches = matchingExistingWindowIndexes(
                for: window,
                in: existing,
                matchSSHTmuxAcrossEndpoint: reconnectSSHWindows
            )
            if matches.count > 1 {
                append(.ambiguousStableIdentity, to: &issues)
                return .init(
                    id: .init(workspaceIndex: imported.index, windowIndex: window.index),
                    name: name,
                    outcome: .conflict,
                    action: .reject,
                    existingWindowIndex: nil,
                    issues: sorted(issues),
                    sourceLocation: location,
                    tmuxPolicy: policy
                )
            }
            guard let match = matches.first else {
                return .init(
                    id: .init(workspaceIndex: imported.index, windowIndex: window.index),
                    name: name,
                    outcome: .create,
                    action: .create(destination),
                    existingWindowIndex: nil,
                    issues: sorted(issues),
                    sourceLocation: location,
                    tmuxPolicy: policy
                )
            }
            if imported.workspace.kind == .local,
               !existing.windows[match].agentTargets.isEmpty,
               existing.windows[match].agentTargets != window.agentTargets {
                append(.activeAgentWouldBeReplaced, to: &issues)
                return .init(
                    id: .init(workspaceIndex: imported.index, windowIndex: window.index),
                    name: name,
                    outcome: .conflict,
                    action: .reject,
                    existingWindowIndex: match,
                    issues: sorted(issues),
                    sourceLocation: location,
                    tmuxPolicy: policy
                )
            }
            let existingWindow = existing.windows[match].window
            let unchanged = canonicalWindow(window.window, workspace: imported.workspace)
                == canonicalWindow(existingWindow, workspace: existing.workspace)
            let requiresReconnect = reconnectSSHWindows && imported.workspace.kind == .ssh
            return .init(
                id: .init(workspaceIndex: imported.index, windowIndex: window.index),
                name: name,
                outcome: unchanged && !requiresReconnect ? .unchanged : .update,
                action: unchanged && !requiresReconnect ? .leaveUnchanged : .update(destination),
                existingWindowIndex: match,
                issues: sorted(issues),
                sourceLocation: location,
                tmuxPolicy: policy
            )
        }
    }

    private func matchingExistingWindowIndexes(
        for imported: WindowMetadata,
        in existing: WorkspaceMetadata,
        matchSSHTmuxAcrossEndpoint: Bool = false
    ) -> [Int] {
        var stable: Set<Int> = []
        if let localWindowID = imported.window.localWindow?.id {
            stable.formUnion(existing.windows.filter {
                $0.window.localWindow?.id == localWindowID
            }.map(\.index))
        }
        for target in imported.agentTargets {
            stable.formUnion(existing.windows.filter {
                $0.agentTargets.contains(target)
            }.map(\.index))
        }
        if matchSSHTmuxAcrossEndpoint,
           let tmux = normalizedOptional(imported.window.tmux) {
            // The workspace match has already established which box is being edited.
            // During A→B endpoint migration, tmux is the window identity even though
            // the canonical endpoint component necessarily changed.
            stable.formUnion(existing.windows.filter {
                normalizedOptional($0.window.tmux) == tmux
            }.map(\.index))
        }
        if let tmuxTarget = imported.tmuxTarget {
            stable.formUnion(existing.windows.filter {
                $0.tmuxTarget == tmuxTarget
            }.map(\.index))
        }
        if !stable.isEmpty { return stable.sorted() }
        guard !imported.normalizedName.isEmpty else { return [] }
        return existing.windows.filter {
            $0.normalizedName == imported.normalizedName
        }.map(\.index)
    }

    private func destination(
        for window: UniConnectDocument.Window,
        workspaceKind: UniConnectWorkspaceKind,
        policy: UniConnectTmuxImportPolicy
    ) -> UniConnectImportPlan.WindowDestination {
        switch workspaceKind {
        case .local:
            if window.localWindow?.runtimeState == .agent,
               let latest = window.localWindow?.latestConversation {
                return .agent(kind: latest.kind, sessionID: latest.sessionID)
            }
            if window.localWindow == nil,
               let session = normalizedOptional(window.claudeSession) {
                return .agent(kind: .claude, sessionID: session)
            }
            return .terminal
        case .ssh:
            let session = normalizedOptional(window.tmux) ?? ""
            if policy == .createIfMissing {
                return .createTmuxIfMissing(session: session)
            }
            return .attachExistingTmux(session: session)
        }
    }

    private func workspacePreview(for metadata: WorkspaceMetadata) -> UniConnectImportPlan.WorkspacePreview {
        UniConnectImportPlan.WorkspacePreview(
            name: metadata.workspace.name,
            kind: metadata.workspace.kind,
            color: metadata.workspace.color,
            group: metadata.workspace.group,
            cwd: metadata.workspace.kind == .local ? metadata.workspace.cwd : nil,
            hostLabel: metadata.workspace.kind == .ssh ? metadata.hostIdentity : nil,
            declaredWindowCount: metadata.workspace.windows.count
        )
    }

    private func resolveDuplicateAgentBindings(
        in document: UniConnectDocument
    ) -> DuplicateAgentResolution {
        var effective = document
        var firstReferenceByTarget: [AgentTarget: WindowRef] = [:]
        var referencesByTarget: [AgentTarget: Set<WindowRef>] = [:]
        var fallbackByReference: [WindowRef: AgentTarget] = [:]

        for workspaceIndex in document.workspaces.indices {
            for windowIndex in document.workspaces[workspaceIndex].windows.indices {
                let reference = WindowRef(workspaceIndex: workspaceIndex, windowIndex: windowIndex)
                let sourceWindow = document.workspaces[workspaceIndex].windows[windowIndex]
                let targets = Set(localAgentTargets(in: sourceWindow))
                for target in targets.sorted(by: agentTargetSort) {
                    if let owner = firstReferenceByTarget[target], owner != reference {
                        referencesByTarget[target, default: [owner]].insert(reference)
                        fallbackByReference[reference] = fallbackByReference[reference] ?? target
                        removeActiveAgentBinding(
                            target,
                            from: &effective.workspaces[workspaceIndex].windows[windowIndex]
                        )
                    } else {
                        firstReferenceByTarget[target] = reference
                    }
                }
            }
        }
        return DuplicateAgentResolution(
            effectiveDocument: effective,
            referencesByTarget: referencesByTarget,
            fallbackByReference: fallbackByReference
        )
    }

    private func removeActiveAgentBinding(
        _ target: AgentTarget,
        from window: inout UniConnectDocument.Window
    ) {
        if target.kind == .claude,
           let value = window.claudeSession,
           value.caseInsensitiveCompare(target.sessionID) == .orderedSame {
            window.claudeSession = nil
        }
        guard var localWindow = window.localWindow else { return }
        if let active = localWindow.activeConversation,
           normalizedAgentTarget(kind: active.kind, sessionID: active.sessionID) == target {
            // History remains append-only; only the second active owner becomes a shell.
            _ = localWindow.transitionToShell(at: localWindow.updatedAt)
        }
        window.localWindow = localWindow
    }

    private func localAgentTargets(in window: UniConnectDocument.Window) -> [AgentTarget] {
        if let localWindow = window.localWindow {
            guard localWindow.runtimeState == .agent,
                  let active = localWindow.activeConversation else {
                return []
            }
            return [normalizedAgentTarget(kind: active.kind, sessionID: active.sessionID)]
        }
        guard let session = normalizedOptional(window.claudeSession) else { return [] }
        return [normalizedAgentTarget(kind: .claude, sessionID: session)]
    }

    private func normalizedAgentTarget(
        kind: RestorableAgentKind,
        sessionID: String
    ) -> AgentTarget {
        guard let claim = UniConnectLocalAgentRestoreClaimPolicy.claim(
            kind: kind,
            sessionID: sessionID
        ) else {
            return AgentTarget(kind: kind, sessionID: sessionID)
        }
        return AgentTarget(
            kind: claim.kind,
            sessionID: claim.sessionID
        )
    }

    private func agentTargetSort(_ lhs: AgentTarget, _ rhs: AgentTarget) -> Bool {
        if lhs.kind.rawValue != rhs.kind.rawValue {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        return lhs.sessionID < rhs.sessionID
    }

    private func connectionIdentity(for connect: String) -> String? {
        guard let session = detectedSSHSession(for: connect),
              let target = UniConnectSSHTargetKey(session: session, tmuxSession: "_") else {
            return nil
        }
        return connectionIdentity(for: target)
    }

    private func detectedSSHSession(for connect: String) -> DetectedSSHSession? {
        guard UniConnectSSH.validateConnectCommand(connect) == nil,
              let validated = UniConnectSSHConnectCommandValidator().validatedCommand(connect) else {
            return nil
        }
        return validated.detectedSession()
    }

    private func connectionIdentity(for target: UniConnectSSHTargetKey) -> String {
        let host = target.host.contains(":") ? "[\(target.host)]" : target.host
        let destination = target.username.map { "\($0)@\(host)" } ?? host
        return "\(destination)#\(target.port)"
    }

    private func absorbStableMatches(
        _ matches: [Int],
        into candidates: inout Set<Int>,
        isAmbiguous: inout Bool
    ) {
        if matches.count > 1 { isAmbiguous = true }
        candidates.formUnion(matches)
    }

    private func appendSourceDiagnostics(
        _ diagnostics: [UniConnectImportDiagnostic],
        to issues: inout [UniConnectImportPlan.Issue]
    ) {
        for diagnostic in diagnostics where diagnostic.severity == .error {
            append(
                .sourceDiagnostic(code: diagnostic.code, line: diagnostic.location.line),
                to: &issues
            )
        }
    }

    private func issueSortKey(_ issue: UniConnectImportPlan.Issue) -> String {
        switch issue {
        case .emptyWorkspaceName: return "00"
        case .missingSSHConnection: return "01"
        case .invalidSSHConnection: return "02"
        case .unexpectedSSHConnection: return "03"
        case .localWorkspaceMissingWindow: return "04"
        case .localWindowHasTmux: return "05"
        case .invalidLocalWorkingDirectory: return "05a"
        case .sshWindowMissingTmux: return "06"
        case .sshWindowHasClaudeSession: return "07"
        case .invalidClaudeSession: return "08"
        case .invalidTmuxSession: return "09"
        case .emptyGroupName: return "10"
        case .pinnedWorkspaceHasGroup: return "11"
        case .duplicateWorkspaceIdentifier(let id): return "12:\(id.uuidString)"
        case .duplicateWorkspaceName: return "13"
        case .duplicateClaudeSession(let id): return "14:\(id.uuidString)"
        case .duplicateAgentSession(let kind, let sessionID):
            return "15:\(kind.rawValue):\(sessionID)"
        case .duplicateTmuxTarget(let host, let session): return "16:\(host):\(session)"
        case .ambiguousStableIdentity: return "17"
        case .ambiguousName: return "18"
        case .workspaceKindMismatch: return "19"
        case .activeAgentWouldBeReplaced: return "20"
        case .sourceDiagnostic(let code, let line): return "21:\(line):\(code.rawValue)"
        }
    }

    private func sorted(_ issues: [UniConnectImportPlan.Issue]) -> [UniConnectImportPlan.Issue] {
        issues.sorted { issueSortKey($0) < issueSortKey($1) }
    }

    private func append(
        _ issue: UniConnectImportPlan.Issue,
        to issues: inout [UniConnectImportPlan.Issue]
    ) {
        if !issues.contains(issue) { issues.append(issue) }
    }

    private func canonicalProperties(
        _ workspace: UniConnectDocument.Workspace
    ) -> CanonicalWorkspaceProperties {
        CanonicalWorkspaceProperties(
            name: workspace.name.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: workspace.kind,
            color: normalizedOptional(workspace.color)?.uppercased(),
            group: normalizedOptional(workspace.group),
            isPinned: workspace.isPinned ?? false,
            cwd: workspace.kind == .local ? normalizedPath(workspace.cwd ?? "~") : nil,
            connect: normalizedOptional(workspace.connect)
        )
    }

    private func canonicalWindow(
        _ window: UniConnectDocument.Window,
        workspace: UniConnectDocument.Workspace
    ) -> CanonicalWindow {
        let localCWD = workspace.kind == .local ? normalizedPath(workspace.cwd ?? "~") : nil
        let localConversations = workspace.kind == .local
            ? (window.localWindow?.conversations ?? [])
            : []
        let legacyClaudeKey = normalizedOptional(window.claudeSession).flatMap {
            UniConnectLocalAgentRestoreClaimPolicy.canonicalKey(kind: .claude, sessionID: $0)
        }
        var localConversationKeys = localConversations.compactMap {
            UniConnectLocalAgentRestoreClaimPolicy.canonicalKey(
                kind: $0.kind,
                sessionID: $0.sessionID
            )
        }
        if localConversationKeys.isEmpty, let legacyClaudeKey {
            localConversationKeys = [legacyClaudeKey]
        }
        let latestLocalConversationKey = window.localWindow?.latestConversation.flatMap {
            UniConnectLocalAgentRestoreClaimPolicy.canonicalKey(
                kind: $0.kind,
                sessionID: $0.sessionID
            )
        } ?? legacyClaudeKey
        return CanonicalWindow(
            name: normalizedOptional(window.name),
            tmux: normalizedOptional(window.tmux),
            claudeSession: normalizedOptional(window.claudeSession)?.lowercased(),
            cwd: workspace.kind == .ssh
                ? nil
                : (normalizedPath(window.cwd)
                    ?? normalizedPath(window.localWindow?.workingDirectory)
                    ?? localCWD),
            isPinned: window.isPinned ?? false,
            localWindowID: window.localWindow?.id,
            runtimeState: window.localWindow?.runtimeState,
            localConversationKeys: localConversationKeys,
            latestLocalConversationKey: latestLocalConversationKey
        )
    }

    private func resolvedTmuxPolicy(
        _ declared: UniConnectTmuxImportPolicy?
    ) -> UniConnectTmuxImportPolicy {
        // Missing/ambiguous policy is deliberately conservative: only an explicit
        // `createIfMissing` declaration may create a remote tmux session.
        declared == .createIfMissing ? .createIfMissing : .attachExisting
    }

    private func normalizedName(_ value: String) -> String {
        let locale = Locale(identifier: "en_US_POSIX")
        return value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
            .lowercased(with: locale)
    }

    private func normalizedOptional(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedPath(_ value: String?) -> String? {
        guard let value = normalizedOptional(value) else { return nil }
        return ((value as NSString).expandingTildeInPath as NSString).standardizingPath
    }

    private func isValidTmuxSession(_ value: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        return !value.isEmpty && value.count <= 40 && value.allSatisfy(allowed.contains)
    }

    private func unique<Element: Hashable>(_ values: [Element]) -> [Element] {
        var seen: Set<Element> = []
        return values.filter { seen.insert($0).inserted }
    }
}
