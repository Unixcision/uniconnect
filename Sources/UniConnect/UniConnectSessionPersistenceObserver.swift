import Combine
import Foundation

/// Converts every recovery-relevant model mutation into an immediate session-save request.
@MainActor
final class UniConnectSessionPersistenceObserver {
    private weak var tabManager: TabManager?
    private let onMutation: @MainActor @Sendable (String) -> Void
    private var managerSubscriptions: Set<AnyCancellable> = []
    private var workspaceSubscriptions: [UUID: Set<AnyCancellable>] = [:]

    init(
        tabManager: TabManager,
        onMutation: @escaping @MainActor @Sendable (String) -> Void
    ) {
        self.tabManager = tabManager
        self.onMutation = onMutation
        installManagerSubscriptions(tabManager)
        replaceWorkspaceSubscriptions(with: tabManager.tabs)
    }

    private func installManagerSubscriptions(_ manager: TabManager) {
        manager.$tabs
            .dropFirst()
            .sink { [weak self] workspaces in
                guard let self else { return }
                self.replaceWorkspaceSubscriptions(with: workspaces)
                self.onMutation("workspace-membership-or-order")
            }
            .store(in: &managerSubscriptions)

        manager.$workspaceGroups
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.onMutation("workspace-group-configuration")
            }
            .store(in: &managerSubscriptions)

        manager.$selectedTabId
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.onMutation("selected-workspace")
            }
            .store(in: &managerSubscriptions)
    }

    private func replaceWorkspaceSubscriptions(with workspaces: [Workspace]) {
        let liveIDs = Set(workspaces.map(\.id))
        workspaceSubscriptions = workspaceSubscriptions.filter { liveIDs.contains($0.key) }
        for workspace in workspaces where workspaceSubscriptions[workspace.id] == nil {
            workspaceSubscriptions[workspace.id] = subscriptions(for: workspace)
        }
    }

    private func subscriptions(for workspace: Workspace) -> Set<AnyCancellable> {
        let publishers: [AnyPublisher<String, Never>] = [
            workspace.$title.removeDuplicates().dropFirst().map { _ in "workspace-name" }.eraseToAnyPublisher(),
            workspace.$customTitle.removeDuplicates().dropFirst().map { _ in "workspace-custom-name" }.eraseToAnyPublisher(),
            workspace.$customDescription.removeDuplicates().dropFirst().map { _ in "workspace-description" }.eraseToAnyPublisher(),
            workspace.$customColor.removeDuplicates().dropFirst().map { _ in "workspace-color" }.eraseToAnyPublisher(),
            workspace.$isPinned.removeDuplicates().dropFirst().map { _ in "workspace-pinned" }.eraseToAnyPublisher(),
            workspace.$groupId.removeDuplicates().dropFirst().map { _ in "workspace-group" }.eraseToAnyPublisher(),
            workspace.$currentDirectory.removeDuplicates().dropFirst().map { _ in "workspace-directory" }.eraseToAnyPublisher(),
            workspace.$panels.map { Set($0.keys) }.removeDuplicates().dropFirst().map { _ in "window-membership" }.eraseToAnyPublisher(),
            workspace.$paneLayoutVersion.removeDuplicates().dropFirst().map { _ in "window-order" }.eraseToAnyPublisher(),
            workspace.$panelDirectories.removeDuplicates().dropFirst().map { _ in "window-directory" }.eraseToAnyPublisher(),
            workspace.$panelTitles.removeDuplicates().dropFirst().map { _ in "window-name" }.eraseToAnyPublisher(),
            workspace.$panelCustomTitles.removeDuplicates().dropFirst().map { _ in "window-custom-name" }.eraseToAnyPublisher(),
            workspace.$pinnedPanelIds.removeDuplicates().dropFirst().map { _ in "window-pinned" }.eraseToAnyPublisher(),
            workspace.$uniConnectProfile.removeDuplicates().dropFirst().map { _ in "connection-profile-reference" }.eraseToAnyPublisher(),
            workspace.$uniConnectTmuxSessionsByPanelId.removeDuplicates().dropFirst().map { _ in "window-tmux-binding" }.eraseToAnyPublisher(),
            workspace.$uniConnectClaudeSessionsByPanelId.removeDuplicates().dropFirst().map { _ in "window-claude-session" }.eraseToAnyPublisher(),
            workspace.$uniConnectLocalWindowsByPanelId.removeDuplicates().dropFirst().map { _ in "window-local-history" }.eraseToAnyPublisher(),
            workspace.$uniConnectDisconnectedPanelIds.removeDuplicates().dropFirst().map { _ in "window-connection-state" }.eraseToAnyPublisher(),
            NotificationCenter.default.publisher(for: .uniConnectClaudeSessionSignal)
                .compactMap { $0.object as? UniConnectClaudeSessionSignal }
                .filter { $0.workspaceID == workspace.id }
                .map { _ in "window-claude-runtime-state" }
                .eraseToAnyPublisher(),
        ]

        var subscriptions: Set<AnyCancellable> = []
        Publishers.MergeMany(publishers)
            .sink { [weak self] reason in
                self?.onMutation(reason)
            }
            .store(in: &subscriptions)
        return subscriptions
    }
}
