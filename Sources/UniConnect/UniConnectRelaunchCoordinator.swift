import CMUXAgentLaunch
import Foundation

/// The one way into relaunching agents, whoever asked.
///
/// Menu item, context menu, phone: all three arrive here. A second path would be a second set of
/// rules about what is safe, and the rules are the whole feature.
@MainActor
final class UniConnectRelaunchCoordinator {
    /// How many windows a request has to touch before it is shown first.
    ///
    /// Counted in **windows and not in scopes**: a box with one window does not deserve a question,
    /// and a machine with twenty does, even though the same menu item produced both. On a phone the
    /// difference between "this box" and "everything" is one stray tap and twenty-six restarted
    /// agents.
    static let confirmationThreshold = 5

    /// What a request would do, handed back before it does it.
    struct Preview {
        let targets: [UniConnectRelaunchExecutor.Target]
        let exclusions: [RelaunchPlan.Exclusion]

        /// Whether this should be shown to a person before it runs.
        var needsConfirmation: Bool {
            targets.count >= UniConnectRelaunchCoordinator.confirmationThreshold
        }
    }

    private let inventory: UniConnectRelaunchInventory
    private let executor: UniConnectRelaunchExecutor

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
        return Preview(targets: reading.items.map(\.target), exclusions: reading.exclusions)
    }

    /// Runs a previewed request, reporting each window on its own.
    ///
    /// Targets are walked one at a time on purpose. Closing twenty-six agents at once would race
    /// them through the same questions, and a question answered for the wrong pane is how a session
    /// dies.
    func run(_ preview: Preview) async -> RelaunchOperation {
        var results: [RelaunchOperation.Result] = []
        for target in preview.targets {
            results.append(await executor.relaunch(target))
        }
        return RelaunchOperation(
            operationID: UUID(),
            verb: .agentRelaunch,
            recovered: false,
            results: results
        )
    }
}
