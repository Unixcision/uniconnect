import Combine
import Foundation
import Observation

/// Owns live workspace observation above the lazy-list snapshot boundary.
@MainActor
@Observable
final class SidebarWorkspaceSnapshotCoordinator {
    private(set) var snapshotsByWorkspaceId: [UUID: SidebarWorkspaceSnapshotBuilder.Snapshot] = [:]

    @ObservationIgnored private var observedWorkspaceIdentities: [ObjectIdentifier] = []
    @ObservationIgnored private var observedSettings: SidebarTabItemSettingsSnapshot?
    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []

    func configure(
        workspaces: [Workspace],
        settings: SidebarTabItemSettingsSnapshot,
        seededSnapshots: [UUID: SidebarWorkspaceSnapshotBuilder.Snapshot] = [:]
    ) {
        let identities = workspaces.map { ObjectIdentifier($0) }
        guard identities != observedWorkspaceIdentities || settings != observedSettings else { return }

        observedWorkspaceIdentities = identities
        observedSettings = settings
        cancellables.removeAll()
        snapshotsByWorkspaceId = Self.makeSnapshotMap(
            elements: workspaces,
            cachedSnapshots: seededSnapshots,
            id: { $0.id },
            project: { Self.project($0, settings: settings) }
        )

        for workspace in workspaces {
            Publishers.MergeMany([
                workspace.sidebarImmediateObservationPublisher,
                workspace.$customTitle
                    .dropFirst()
                    .removeDuplicates()
                    .map { _ in () }
                    .eraseToAnyPublisher(),
                workspace.$groupId
                    .dropFirst()
                    .removeDuplicates()
                    .map { _ in () }
                    .eraseToAnyPublisher(),
                workspace.$uniConnectProfile
                    .dropFirst()
                    .removeDuplicates()
                    .map { _ in () }
                    .eraseToAnyPublisher(),
                workspace.$uniConnectTmuxSessionsByPanelId
                    .dropFirst()
                    .removeDuplicates()
                    .map { _ in () }
                    .eraseToAnyPublisher(),
            ])
                .receive(on: RunLoop.main)
                .sink { [weak self, weak workspace] _ in
                    guard let self, let workspace else { return }
                    self.refresh(workspace, settings: settings)
                }
                .store(in: &cancellables)

            workspace.sidebarObservationPublisher
                .receive(on: RunLoop.main)
                .debounce(for: .milliseconds(40), scheduler: RunLoop.main)
                .sink { [weak self, weak workspace] _ in
                    guard let self, let workspace else { return }
                    self.refresh(workspace, settings: settings)
                }
                .store(in: &cancellables)
        }
    }

    func snapshots(
        for workspaces: [Workspace],
        settings: SidebarTabItemSettingsSnapshot
    ) -> [UUID: SidebarWorkspaceSnapshotBuilder.Snapshot] {
        // Read the observable cache even before configure() has run. This makes
        // the first seeded assignment establish the parent view's observation
        // dependency instead of leaving later publisher refreshes invisible.
        let cachedSnapshots = snapshotsByWorkspaceId
        let identities = workspaces.map { ObjectIdentifier($0) }
        let canReuseCache = observedSettings == settings && identities == observedWorkspaceIdentities
        return Self.makeSnapshotMap(
            elements: workspaces,
            cachedSnapshots: canReuseCache ? cachedSnapshots : [:],
            id: { $0.id },
            project: { Self.project($0, settings: settings) }
        )
    }

    /// Returns one snapshot per unique identifier, projecting only cache misses.
    static func makeSnapshotMap<Element, ID: Hashable, Snapshot>(
        elements: [Element],
        cachedSnapshots: [ID: Snapshot],
        id: (Element) -> ID,
        project: (Element) -> Snapshot
    ) -> [ID: Snapshot] {
        var result: [ID: Snapshot] = [:]
        result.reserveCapacity(elements.count)
        for element in elements {
            let elementId = id(element)
            guard !result.keys.contains(elementId) else { continue }
            result[elementId] = cachedSnapshots[elementId] ?? project(element)
        }
        return result
    }

    private func refresh(_ workspace: Workspace, settings: SidebarTabItemSettingsSnapshot) {
        guard observedSettings == settings,
              observedWorkspaceIdentities.contains(ObjectIdentifier(workspace)) else {
            return
        }
        let nextSnapshot = Self.project(workspace, settings: settings)
        guard snapshotsByWorkspaceId[workspace.id] != nextSnapshot else { return }
        snapshotsByWorkspaceId[workspace.id] = nextSnapshot
    }

    private static func project(
        _ workspace: Workspace,
        settings: SidebarTabItemSettingsSnapshot
    ) -> SidebarWorkspaceSnapshotBuilder.Snapshot {
        SidebarWorkspaceSnapshotProjector(workspace: workspace, settings: settings).project()
    }
}
