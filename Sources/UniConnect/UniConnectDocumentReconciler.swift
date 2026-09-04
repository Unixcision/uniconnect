import Foundation

/// Applies planned create/update rows to a document without deleting unmentioned windows.
struct UniConnectDocumentReconciler {
    enum ReconciliationError: Error, Equatable {
        case duplicateWorkspace
        case missingWorkspace
        case ambiguousWorkspace
        case ambiguousWindow
        case invalidOutcome
    }

    func applying(
        _ mutation: UniConnectImportMutation,
        to document: UniConnectDocument
    ) throws -> UniConnectDocument {
        var result = document
        switch mutation.outcome {
        case .create:
            guard matchingWorkspaceIndexes(for: mutation, in: result).isEmpty else {
                throw ReconciliationError.duplicateWorkspace
            }
            result.workspaces.append(mutation.workspace)
        case .update:
            let matches = matchingWorkspaceIndexes(for: mutation, in: result)
            guard !matches.isEmpty else { throw ReconciliationError.missingWorkspace }
            guard matches.count == 1, let index = matches.first else {
                throw ReconciliationError.ambiguousWorkspace
            }
            result.workspaces[index] = try merged(
                imported: mutation.workspace,
                existing: result.workspaces[index]
            )
        case .unchanged, .conflict, .rejected:
            throw ReconciliationError.invalidOutcome
        }
        return result
    }

    private func matchingWorkspaceIndexes(
        for mutation: UniConnectImportMutation,
        in document: UniConnectDocument
    ) -> [Int] {
        if let id = mutation.existingWorkspaceID {
            let matches = document.workspaces.indices.filter { document.workspaces[$0].id == id }
            if !matches.isEmpty { return matches }
        }
        if let index = mutation.existingWorkspaceIndex,
           document.workspaces.indices.contains(index) {
            return [index]
        }
        if let importedID = mutation.workspace.id {
            let matches = document.workspaces.indices.filter { document.workspaces[$0].id == importedID }
            if !matches.isEmpty { return matches }
        }
        let name = normalizedName(mutation.workspace.name)
        return document.workspaces.indices.filter {
            normalizedName(document.workspaces[$0].name) == name
        }
    }

    private func merged(
        imported: UniConnectDocument.Workspace,
        existing: UniConnectDocument.Workspace
    ) throws -> UniConnectDocument.Workspace {
        guard imported.kind == existing.kind else {
            throw ReconciliationError.ambiguousWorkspace
        }
        var merged = existing
        merged.id = imported.id ?? existing.id
        merged.name = imported.name
        merged.color = imported.color
        merged.group = imported.group
        merged.isPinned = imported.isPinned
        merged.cwd = imported.cwd
        merged.connect = imported.connect

        for window in imported.windows {
            let matches = matchingWindowIndexes(
                imported: window,
                workspaceKind: imported.kind,
                in: merged.windows
            )
            guard matches.count <= 1 else {
                throw ReconciliationError.ambiguousWindow
            }
            if let index = matches.first {
                merged.windows[index] = window
            } else {
                merged.windows.append(window)
            }
        }
        return merged
    }

    private func matchingWindowIndexes(
        imported: UniConnectDocument.Window,
        workspaceKind: UniConnectWorkspaceKind,
        in existing: [UniConnectDocument.Window]
    ) -> [Int] {
        if let id = imported.localWindow?.id {
            let matches = existing.indices.filter { existing[$0].localWindow?.id == id }
            if !matches.isEmpty { return matches }
        }
        switch workspaceKind {
        case .local:
            let targets = Set(localAgentKeys(imported))
            if !targets.isEmpty {
                let matches = existing.indices.filter {
                    !targets.isDisjoint(with: Set(localAgentKeys(existing[$0])))
                }
                if !matches.isEmpty { return matches }
            }
        case .ssh:
            if let tmux = normalizedOptional(imported.tmux) {
                let matches = existing.indices.filter {
                    normalizedOptional(existing[$0].tmux) == tmux
                }
                if !matches.isEmpty { return matches }
            }
        }
        guard let name = normalizedOptional(imported.name) else { return [] }
        let normalized = normalizedName(name)
        return existing.indices.filter {
            normalizedName(existing[$0].name ?? "") == normalized
        }
    }

    private func localAgentKeys(_ window: UniConnectDocument.Window) -> [String] {
        var keys: [String] = []
        if let session = normalizedOptional(window.claudeSession) {
            keys.append(RestorableAgentKind.claude.rawValue + "\u{0}" + session.lowercased())
        }
        for conversation in window.localWindow?.conversations ?? [] {
            keys.append(
                conversation.kind.rawValue
                    + "\u{0}"
                    + (conversation.kind == .claude
                        ? conversation.sessionID.lowercased()
                        : conversation.sessionID)
            )
        }
        return keys
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
}
