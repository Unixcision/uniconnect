import Foundation

/// Builds deterministic import outcomes without mutating workspaces, panels, or the vault.
struct UniConnectImportPlanner {
    private struct TmuxTarget: Hashable {
        let host: String
        let session: String
    }

    private struct WorkspaceMetadata {
        let index: Int
        let workspace: UniConnectDocument.Workspace
        let normalizedName: String
        let claudeSessions: [UUID]
        let tmuxTargets: [TmuxTarget]
        let validationIssues: [UniConnectImportPlan.Issue]
    }

    private struct CanonicalWindow: Equatable {
        let name: String?
        let tmux: String?
        let claudeSession: String?
        let cwd: String?
        let isPinned: Bool
    }

    private struct CanonicalWorkspace: Equatable {
        let name: String
        let kind: UniConnectWorkspaceKind
        let color: String?
        let group: String?
        let isPinned: Bool
        let cwd: String?
        let connect: String?
        let windows: [CanonicalWindow]
    }

    /// Plans an imported document against a snapshot of the current UniConnect document.
    func plan(
        importing document: UniConnectDocument,
        against existingDocument: UniConnectDocument
    ) -> UniConnectImportPlan {
        let imported = document.workspaces.enumerated().map {
            metadata(for: $0.element, index: $0.offset, validate: true)
        }
        let existing = existingDocument.workspaces.enumerated().map {
            metadata(for: $0.element, index: $0.offset, validate: false)
        }
        var issuesByImportedIndex = imported.map(\.validationIssues)

        var importedWorkspaceIDs: [UUID: [Int]] = [:]
        var importedNames: [String: [Int]] = [:]
        var importedClaudeSessions: [UUID: [Int]] = [:]
        var importedTmuxTargets: [TmuxTarget: [Int]] = [:]
        for item in imported {
            if let id = item.workspace.id {
                importedWorkspaceIDs[id, default: []].append(item.index)
            }
            if !item.normalizedName.isEmpty {
                importedNames[item.normalizedName, default: []].append(item.index)
            }
            for session in item.claudeSessions {
                importedClaudeSessions[session, default: []].append(item.index)
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
        for (session, indexes) in importedClaudeSessions where indexes.count > 1 {
            for index in Set(indexes).sorted() {
                append(.duplicateClaudeSession(session), to: &issuesByImportedIndex[index])
            }
        }
        for (target, indexes) in importedTmuxTargets where indexes.count > 1 {
            for index in Set(indexes).sorted() {
                append(
                    .duplicateTmuxTarget(host: target.host, session: target.session),
                    to: &issuesByImportedIndex[index]
                )
            }
        }

        var existingWorkspaceIDs: [UUID: [Int]] = [:]
        var existingNames: [String: [Int]] = [:]
        var existingClaudeSessions: [UUID: [Int]] = [:]
        var existingTmuxTargets: [TmuxTarget: [Int]] = [:]
        for item in existing {
            if let id = item.workspace.id {
                existingWorkspaceIDs[id, default: []].append(item.index)
            }
            if !item.normalizedName.isEmpty {
                existingNames[item.normalizedName, default: []].append(item.index)
            }
            for session in item.claudeSessions {
                existingClaudeSessions[session, default: []].append(item.index)
            }
            for target in item.tmuxTargets {
                existingTmuxTargets[target, default: []].append(item.index)
            }
        }

        let rows = imported.map { item -> UniConnectImportPlan.Row in
            var issues = issuesByImportedIndex[item.index]
            if !item.validationIssues.isEmpty {
                return row(for: item, existing: nil, outcome: .rejected, issues: issues)
            }
            if !issues.isEmpty {
                return row(for: item, existing: nil, outcome: .conflict, issues: issues)
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
            for session in item.claudeSessions {
                absorbStableMatches(
                    existingClaudeSessions[session] ?? [],
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
                return row(for: item, existing: nil, outcome: .conflict, issues: issues)
            }

            let nameMatches = existingNames[item.normalizedName] ?? []
            let existingIndex: Int?
            if let stableMatch = stableCandidates.first {
                if nameMatches.contains(where: { $0 != stableMatch }) {
                    append(.ambiguousName, to: &issues)
                    return row(for: item, existing: nil, outcome: .conflict, issues: issues)
                }
                existingIndex = stableMatch
            } else {
                if nameMatches.count > 1 {
                    append(.ambiguousName, to: &issues)
                    return row(for: item, existing: nil, outcome: .conflict, issues: issues)
                }
                existingIndex = nameMatches.first
            }

            guard let existingIndex else {
                return row(for: item, existing: nil, outcome: .create, issues: issues)
            }
            let existingItem = existing[existingIndex]
            guard item.workspace.kind == existingItem.workspace.kind else {
                append(.workspaceKindMismatch, to: &issues)
                return row(for: item, existing: existingItem, outcome: .conflict, issues: issues)
            }

            let outcome: UniConnectImportPlan.Outcome =
                canonical(item.workspace) == canonical(existingItem.workspace) ? .unchanged : .update
            return row(for: item, existing: existingItem, outcome: outcome, issues: issues)
        }

        return UniConnectImportPlan(rows: rows)
    }

    private func metadata(
        for workspace: UniConnectDocument.Workspace,
        index: Int,
        validate: Bool
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

        let connect = normalizedOptional(workspace.connect)
        let hostIdentity: String?
        switch workspace.kind {
        case .local:
            hostIdentity = nil
            if validate, connect != nil {
                append(.unexpectedSSHConnection, to: &issues)
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

        var claudeSessions: [UUID] = []
        var tmuxTargets: [TmuxTarget] = []
        for window in workspace.windows {
            let tmux = normalizedOptional(window.tmux)
            let claude = normalizedOptional(window.claudeSession)
            if let claude {
                if let session = UUID(uuidString: claude) {
                    claudeSessions.append(session)
                } else if validate {
                    append(.invalidClaudeSession, to: &issues)
                }
            }

            switch workspace.kind {
            case .local:
                if validate, tmux != nil { append(.localWindowHasTmux, to: &issues) }
            case .ssh:
                if validate, claude != nil { append(.sshWindowHasClaudeSession, to: &issues) }
                guard let tmux else {
                    if validate { append(.sshWindowMissingTmux, to: &issues) }
                    continue
                }
                guard isValidTmuxSession(tmux) else {
                    if validate { append(.invalidTmuxSession, to: &issues) }
                    continue
                }
                if let hostIdentity {
                    tmuxTargets.append(TmuxTarget(host: hostIdentity, session: tmux))
                }
            }
        }

        return WorkspaceMetadata(
            index: index,
            workspace: workspace,
            normalizedName: name,
            claudeSessions: claudeSessions,
            tmuxTargets: tmuxTargets,
            validationIssues: issues
        )
    }

    private func connectionIdentity(for connect: String) -> String? {
        if let session = UniConnectSSH.detectedSession(fromConnectCommand: connect) {
            return "\(normalizedName(session.destination))#\(session.port ?? 22)"
        }
        let label = normalizedName(UniConnectSSH.hostLabel(from: connect))
        return label == "servidor" ? nil : label
    }

    private func absorbStableMatches(
        _ matches: [Int],
        into candidates: inout Set<Int>,
        isAmbiguous: inout Bool
    ) {
        if matches.count > 1 { isAmbiguous = true }
        candidates.formUnion(matches)
    }

    private func row(
        for imported: WorkspaceMetadata,
        existing: WorkspaceMetadata?,
        outcome: UniConnectImportPlan.Outcome,
        issues: [UniConnectImportPlan.Issue]
    ) -> UniConnectImportPlan.Row {
        UniConnectImportPlan.Row(
            sourceIndex: imported.index,
            workspace: imported.workspace,
            existingWorkspaceID: existing?.workspace.id,
            outcome: outcome,
            issues: issues.sorted { issueSortKey($0) < issueSortKey($1) }
        )
    }

    private func issueSortKey(_ issue: UniConnectImportPlan.Issue) -> String {
        switch issue {
        case .emptyWorkspaceName: return "00"
        case .missingSSHConnection: return "01"
        case .invalidSSHConnection: return "02"
        case .unexpectedSSHConnection: return "03"
        case .localWorkspaceMissingWindow: return "04"
        case .localWindowHasTmux: return "05"
        case .sshWindowMissingTmux: return "06"
        case .sshWindowHasClaudeSession: return "07"
        case .invalidClaudeSession: return "08"
        case .invalidTmuxSession: return "09"
        case .emptyGroupName: return "10"
        case .pinnedWorkspaceHasGroup: return "11"
        case .duplicateWorkspaceIdentifier(let id): return "12:\(id.uuidString)"
        case .duplicateWorkspaceName: return "13"
        case .duplicateClaudeSession(let id): return "14:\(id.uuidString)"
        case .duplicateTmuxTarget(let host, let session): return "15:\(host):\(session)"
        case .ambiguousStableIdentity: return "16"
        case .ambiguousName: return "17"
        case .workspaceKindMismatch: return "18"
        }
    }

    private func append(
        _ issue: UniConnectImportPlan.Issue,
        to issues: inout [UniConnectImportPlan.Issue]
    ) {
        if !issues.contains(issue) { issues.append(issue) }
    }

    private func canonical(_ workspace: UniConnectDocument.Workspace) -> CanonicalWorkspace {
        let localCWD = workspace.kind == .local ? normalizedPath(workspace.cwd ?? "~") : nil
        return CanonicalWorkspace(
            name: workspace.name.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: workspace.kind,
            color: normalizedOptional(workspace.color)?.uppercased(),
            group: normalizedOptional(workspace.group),
            isPinned: workspace.isPinned ?? false,
            cwd: localCWD,
            connect: normalizedOptional(workspace.connect),
            windows: workspace.windows.map { window in
                CanonicalWindow(
                    name: normalizedOptional(window.name),
                    tmux: normalizedOptional(window.tmux),
                    claudeSession: normalizedOptional(window.claudeSession)?.lowercased(),
                    cwd: workspace.kind == .ssh
                        ? nil
                        : (normalizedPath(window.cwd) ?? localCWD),
                    isPinned: window.isPinned ?? false
                )
            }
        )
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
}
