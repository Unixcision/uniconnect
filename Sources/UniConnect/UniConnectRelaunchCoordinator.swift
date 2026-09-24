import CMUXAgentLaunch
import Foundation

/// The one way into relaunching agents, whoever asked.
///
/// Menu item, context menu, phone: all three arrive here, and through **one instance** owned by
/// ``UniConnectCoordinator`` (`relaunchService`). A second path would be a second set of rules
/// about what is safe, and the rules are the whole feature; a second instance would be a second
/// idea of which panes are already being handled.
@MainActor
final class UniConnectRelaunchCoordinator {
    /// How many windows a request has to touch before it is shown first.
    ///
    /// Counted in **windows and not in scopes**: a box with one window does not deserve a question,
    /// and a machine with twenty does, even though the same menu item produced both. On a phone the
    /// difference between "this box" and "everything" is one stray tap and twenty-six restarted
    /// agents.
    static let confirmationThreshold = 5

    /// A window set aside, with the panel it belongs to when there is one.
    struct ExcludedWindow {
        let panelID: UUID?
        let exclusion: RelaunchPlan.Exclusion
    }

    /// What a request would do, handed back before it does it.
    struct Preview {
        let targets: [UniConnectRelaunchExecutor.Target]
        let excluded: [ExcludedWindow]

        var exclusions: [RelaunchPlan.Exclusion] { excluded.map(\.exclusion) }

        init(targets: [UniConnectRelaunchExecutor.Target], excluded: [ExcludedWindow]) {
            self.targets = targets
            self.excluded = excluded
        }

        /// A preview whose exclusions are not tied to any panel (refusals, recovered operations).
        init(targets: [UniConnectRelaunchExecutor.Target], exclusions: [RelaunchPlan.Exclusion]) {
            self.init(targets: targets, excluded: exclusions.map { ExcludedWindow(panelID: nil, exclusion: $0) })
        }

        /// Whether this should be shown to a person before it runs.
        var needsConfirmation: Bool {
            targets.count >= UniConnectRelaunchCoordinator.confirmationThreshold
        }

        /// Keeps only what concerns the requested windows: their targets (by tmux session) and
        /// their exclusions (by panel identity, never by matching label text).
        func restricted(toPanels panels: Set<UUID>, sessions: Set<String>) -> Preview {
            Preview(
                targets: targets.filter { sessions.contains($0.session) },
                excluded: excluded.filter { entry in entry.panelID.map { panels.contains($0) } ?? false }
            )
        }
    }

    private let inventory: UniConnectRelaunchInventory
    private let executor: UniConnectRelaunchExecutor
    /// Panes being closed and reopened right now, by desktop or phone alike.
    private var inFlightPanes: Set<String> = []

    init(
        machineID: String,
        inventory: UniConnectRelaunchInventory? = nil,
        executor: UniConnectRelaunchExecutor = UniConnectRelaunchExecutor()
    ) {
        self.inventory = inventory ?? UniConnectRelaunchInventory(machineID: machineID)
        self.executor = executor
    }

    /// Looks at `workspaces` without touching anything.
    func preview(workspaces: [Workspace]) -> Preview {
        let reading = inventory.read(workspaces: workspaces)
        return Preview(targets: reading.items.map(\.target), excluded: reading.excluded)
    }

    /// Runs a previewed request, reporting each window on its own.
    ///
    /// Targets are walked one at a time on purpose. Closing twenty-six agents at once would race
    /// them through the same questions, and a question answered for the wrong pane is how a session
    /// dies. A pane another request is already handling is reported as ``RelaunchCause/duplicate``
    /// and left alone.
    func run(_ preview: Preview) async -> RelaunchOperation {
        var results: [RelaunchOperation.Result] = []
        for target in preview.targets {
            let pane = target.key.paneIdentity
            guard inFlightPanes.insert(pane).inserted else {
                results.append(.init(key: target.key, state: .skipped, cause: .duplicate))
                continue
            }
            let result = await executor.relaunch(target)
            inFlightPanes.remove(pane)
            results.append(result)
        }
        return RelaunchOperation(
            operationID: UUID(),
            verb: .agentRelaunch,
            recovered: false,
            results: results
        )
    }
}
