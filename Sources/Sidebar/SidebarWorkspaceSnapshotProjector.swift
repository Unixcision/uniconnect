import Foundation

/// Projects a live workspace into the immutable value consumed by a sidebar row.
@MainActor
struct SidebarWorkspaceSnapshotProjector {
    private static let legacyVMWebSocketDescription = "VM WebSocket PTY"

    let workspace: Workspace
    let settings: SidebarTabItemSettingsSnapshot

    func project() -> SidebarWorkspaceSnapshotBuilder.Snapshot {
        let detailVisibility = settings.visibleAuxiliaryDetails
        let orderedPanelIds: [UUID]? = (
            detailVisibility.showsBranchDirectory || detailVisibility.showsPullRequests
        ) ? workspace.sidebarOrderedPanelIds() : nil
        let compactGitBranchSummaryText: String? = {
            guard detailVisibility.showsBranchDirectory,
                  !settings.usesVerticalBranchLayout,
                  settings.showsGitBranch,
                  let orderedPanelIds else {
                return nil
            }
            return gitBranchSummaryText(orderedPanelIds: orderedPanelIds)
        }()
        let compactDirectoryCandidates: [String] = {
            guard detailVisibility.showsBranchDirectory,
                  !settings.usesVerticalBranchLayout,
                  let orderedPanelIds else {
                return []
            }
            return compactDirectoryCandidatesList(orderedPanelIds: orderedPanelIds)
        }()
        let compactBranchDirectoryCandidates = compactBranchDirectoryCandidatesList(
            gitSummary: compactGitBranchSummaryText,
            directoryCandidates: compactDirectoryCandidates
        )
        let branchDirectoryLines: [SidebarWorkspaceSnapshotBuilder.VerticalBranchDirectoryLine] = {
            guard detailVisibility.showsBranchDirectory,
                  settings.usesVerticalBranchLayout,
                  let orderedPanelIds else {
                return []
            }
            return verticalBranchDirectoryLines(orderedPanelIds: orderedPanelIds)
        }()
        let branchLinesContainBranch = settings.showsGitBranch && branchDirectoryLines.contains {
            $0.branch != nil
        }
        let pullRequestRows: [SidebarWorkspaceSnapshotBuilder.PullRequestDisplay] = {
            guard detailVisibility.showsPullRequests, let orderedPanelIds else { return [] }
            return pullRequestDisplays(orderedPanelIds: orderedPanelIds)
        }()

        return SidebarWorkspaceSnapshotBuilder.Snapshot(
            presentationKey: presentationKey,
            title: workspace.title,
            customDescription: settings.showsWorkspaceDescription ? visibleCustomDescription : nil,
            isPinned: workspace.isPinned,
            customColorHex: workspace.customColor,
            remoteWorkspaceSidebarText: remoteWorkspaceSidebarText,
            remoteConnectionStatusText: remoteConnectionStatusText,
            remoteStateHelpText: remoteStateHelpText,
            copyableSidebarSSHError: copyableSidebarSSHError,
            latestConversationMessage: workspace.latestConversationMessage,
            metadataEntries: detailVisibility.showsMetadata
                ? workspace.sidebarStatusEntriesInDisplayOrder()
                : [],
            metadataBlocks: detailVisibility.showsMetadata
                ? workspace.sidebarMetadataBlocksInDisplayOrder()
                : [],
            latestLog: detailVisibility.showsLog ? workspace.logEntries.last : nil,
            progress: detailVisibility.showsProgress ? workspace.progress : nil,
            compactGitBranchSummaryText: compactGitBranchSummaryText,
            compactDirectoryCandidates: compactDirectoryCandidates,
            compactBranchDirectoryCandidates: compactBranchDirectoryCandidates,
            branchDirectoryLines: branchDirectoryLines,
            branchLinesContainBranch: branchLinesContainBranch,
            pullRequestRows: pullRequestRows,
            listeningPorts: detailVisibility.showsPorts ? workspace.listeningPorts : [],
            uniConnectIsSSH: workspace.uniConnectProfile?.isSSH,
            uniConnectWindowCount: workspace.uniConnectProfile == nil
                ? 0
                : workspace.uniConnectOrderedTerminalPanelIds().count,
            customTitle: workspace.customTitle,
            groupId: workspace.groupId,
            finderDirectoryPath: WorkspaceFinderDirectoryResolver.path(for: workspace),
            canReconnectSSH: workspace.uniConnectTmuxSessionsByPanelId.keys.contains {
                workspace.panels[$0] != nil
            }
        )
    }

    private var presentationKey: SidebarWorkspaceSnapshotBuilder.PresentationKey {
        SidebarWorkspaceSnapshotBuilder.PresentationKey(
            showsWorkspaceDescription: settings.showsWorkspaceDescription,
            usesVerticalBranchLayout: settings.usesVerticalBranchLayout,
            showsGitBranch: settings.showsGitBranch,
            usesViewportAwarePath: settings.usesLastSegmentPath,
            visibleAuxiliaryDetails: settings.visibleAuxiliaryDetails
        )
    }

    private var visibleCustomDescription: String? {
        guard let description = workspace.customDescription else { return nil }
        if workspace.title.hasPrefix("vm:"),
           description.trimmingCharacters(in: .whitespacesAndNewlines) == Self.legacyVMWebSocketDescription {
            return nil
        }
        return description
    }

    private var remoteWorkspaceSidebarText: String? {
        guard workspace.hasActiveRemoteTerminalSessions else { return nil }
        let trimmedTarget = workspace.remoteDisplayTarget?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedTarget, !trimmedTarget.isEmpty {
            return trimmedTarget
        }
        return String(localized: "sidebar.remote.subtitleFallback", defaultValue: "SSH workspace")
    }

    private var copyableSidebarSSHError: String? {
        let fallbackTarget = workspace.remoteDisplayTarget ?? String(
            localized: "sidebar.remote.help.targetFallback",
            defaultValue: "remote host"
        )
        let trimmedDetail = workspace.remoteConnectionDetail?.trimmingCharacters(in: .whitespacesAndNewlines)
        if workspace.remoteConnectionState == .error, let trimmedDetail, !trimmedDetail.isEmpty {
            let entry = SidebarRemoteErrorCopyEntry(
                workspaceTitle: workspace.title,
                target: fallbackTarget,
                detail: trimmedDetail
            )
            return SidebarRemoteErrorCopySupport.clipboardText(for: [entry])
        }
        if let statusValue = workspace.statusEntries["remote.error"]?.value
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !statusValue.isEmpty {
            let entry = SidebarRemoteErrorCopyEntry(
                workspaceTitle: workspace.title,
                target: fallbackTarget,
                detail: statusValue
            )
            return SidebarRemoteErrorCopySupport.clipboardText(for: [entry])
        }
        return nil
    }

    private var remoteConnectionStatusText: String {
        switch workspace.remoteConnectionState {
        case .connected:
            return String(localized: "remote.status.connected", defaultValue: "Connected")
        case .connecting:
            return String(localized: "remote.status.connecting", defaultValue: "Connecting")
        case .reconnecting:
            return String(localized: "remote.status.reconnecting", defaultValue: "Reconnecting")
        case .error:
            return String(localized: "remote.status.error", defaultValue: "Error")
        case .disconnected:
            return String(localized: "remote.status.disconnected", defaultValue: "Disconnected")
        }
    }

    private var remoteStateHelpText: String {
        let target = workspace.remoteDisplayTarget ?? String(
            localized: "sidebar.remote.help.targetFallback",
            defaultValue: "remote host"
        )
        let detail = workspace.remoteConnectionDetail?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch workspace.remoteConnectionState {
        case .connected:
            return formattedRemoteHelp(
                key: "sidebar.remote.help.connected",
                defaultValue: "SSH connected to %@",
                target: target
            )
        case .connecting:
            return formattedRemoteHelp(
                key: "sidebar.remote.help.connecting",
                defaultValue: "SSH connecting to %@",
                target: target
            )
        case .reconnecting:
            return formattedRemoteHelp(
                key: "sidebar.remote.help.reconnecting",
                defaultValue: "SSH reconnecting to %@",
                target: target
            )
        case .error:
            if let detail, !detail.isEmpty {
                return String(
                    format: String(
                        localized: "sidebar.remote.help.errorWithDetail",
                        defaultValue: "SSH error for %@: %@"
                    ),
                    locale: .current,
                    target,
                    detail
                )
            }
            return formattedRemoteHelp(
                key: "sidebar.remote.help.error",
                defaultValue: "SSH error for %@",
                target: target
            )
        case .disconnected:
            return formattedRemoteHelp(
                key: "sidebar.remote.help.disconnected",
                defaultValue: "SSH disconnected from %@",
                target: target
            )
        }
    }

    private func formattedRemoteHelp(
        key: StaticString,
        defaultValue: String.LocalizationValue,
        target: String
    ) -> String {
        String(
            format: String(localized: key, defaultValue: defaultValue),
            locale: .current,
            target
        )
    }

    private func compactBranchDirectoryCandidatesList(
        gitSummary: String?,
        directoryCandidates: [String]
    ) -> [String] {
        if directoryCandidates.isEmpty {
            return gitSummary.flatMap { $0.isEmpty ? nil : [$0] } ?? []
        }
        guard let gitSummary, !gitSummary.isEmpty else { return directoryCandidates }
        return directoryCandidates.map { "\(gitSummary) · \($0)" }
    }

    private func gitBranchSummaryText(orderedPanelIds: [UUID]) -> String? {
        let lines = workspace.sidebarGitBranchesInDisplayOrder(orderedPanelIds: orderedPanelIds).map { branch in
            "\(branch.branch)\(branch.isDirty ? "*" : "")"
        }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: " | ")
    }

    private func verticalBranchDirectoryLines(
        orderedPanelIds: [UUID]
    ) -> [SidebarWorkspaceSnapshotBuilder.VerticalBranchDirectoryLine] {
        let entries = workspace.sidebarBranchDirectoryEntriesInDisplayOrder(orderedPanelIds: orderedPanelIds)
        let home = SidebarPathFormatter.homeDirectoryPath
        return entries.compactMap { entry in
            let branchText: String? = {
                guard settings.showsGitBranch, let branch = entry.branch else { return nil }
                return "\(branch)\(entry.isDirty ? "*" : "")"
            }()
            let directoryCandidates: [String] = {
                guard let directory = entry.directory else { return [] }
                if settings.usesLastSegmentPath {
                    return SidebarPathFormatter.pathCandidates(directory, homeDirectoryPath: home)
                }
                let shortened = SidebarPathFormatter.shortenedPath(directory, homeDirectoryPath: home)
                return shortened.isEmpty ? [] : [shortened]
            }()
            guard branchText != nil || !directoryCandidates.isEmpty else { return nil }
            return SidebarWorkspaceSnapshotBuilder.VerticalBranchDirectoryLine(
                branch: branchText,
                directoryCandidates: directoryCandidates
            )
        }
    }

    private func compactDirectoryCandidatesList(orderedPanelIds: [UUID]) -> [String] {
        let home = SidebarPathFormatter.homeDirectoryPath
        let directories = workspace.sidebarDirectoriesInDisplayOrder(orderedPanelIds: orderedPanelIds)
        guard !directories.isEmpty else { return [] }

        if !settings.usesLastSegmentPath {
            let joined = directories
                .map { SidebarPathFormatter.shortenedPath($0, homeDirectoryPath: home) }
                .filter { !$0.isEmpty }
                .joined(separator: " | ")
            return joined.isEmpty ? [] : [joined]
        }

        let perDirectoryCandidates = directories
            .map { SidebarPathFormatter.pathCandidates($0, homeDirectoryPath: home) }
            .filter { !$0.isEmpty }
        guard !perDirectoryCandidates.isEmpty else { return [] }

        var indices = Array(repeating: 0, count: perDirectoryCandidates.count)
        var result: [String] = []
        while true {
            let pieces = zip(indices, perDirectoryCandidates).map { index, candidates in
                candidates[index]
            }
            let joined = pieces.joined(separator: " | ")
            if !joined.isEmpty, result.last != joined {
                result.append(joined)
            }
            guard let bumpIndex = indices.indices.last(where: {
                indices[$0] < perDirectoryCandidates[$0].count - 1
            }) else {
                break
            }
            indices[bumpIndex] += 1
        }
        return result
    }

    private func pullRequestDisplays(
        orderedPanelIds: [UUID]
    ) -> [SidebarWorkspaceSnapshotBuilder.PullRequestDisplay] {
        workspace.sidebarPullRequestsInDisplayOrder(orderedPanelIds: orderedPanelIds).map { pullRequest in
            SidebarWorkspaceSnapshotBuilder.PullRequestDisplay(
                id: "\(pullRequest.label.lowercased())#\(pullRequest.number)|\(pullRequest.url.absoluteString)",
                number: pullRequest.number,
                label: pullRequest.label,
                url: pullRequest.url,
                status: pullRequest.status,
                isStale: pullRequest.isStale
            )
        }
    }
}
