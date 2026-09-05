import Foundation
import UniConnectClaudeBridge

/// Main-actor adapter from the bridge domain into UniConnect's existing notification center.
@MainActor
final class UniConnectClaudeBridgeNotificationSink: ClaudeBridgeNotificationDelivering {
    typealias TabManagersProvider = @MainActor @Sendable () -> [TabManager]

    private let tabManagersProvider: TabManagersProvider
    private let notificationStore: TerminalNotificationStore

    init(
        tabManagersProvider: @escaping TabManagersProvider,
        notificationStore: TerminalNotificationStore
    ) {
        self.tabManagersProvider = tabManagersProvider
        self.notificationStore = notificationStore
    }

    /// Resolves the current owner of a stable surface. The route's workspace is authoritative
    /// while it still owns the surface; the surface lookup handles an in-process tab move that
    /// happened after the SSH command (and therefore its signed route) was created.
    static func workspace(
        for route: ClaudeBridgeRoute,
        in tabManagers: [TabManager]
    ) -> Workspace? {
        var movedSurfaceOwner: Workspace?
        for manager in tabManagers {
            for workspace in manager.tabs where workspace.panels[route.surfaceID] != nil {
                if workspace.id == route.workspaceID {
                    return workspace
                }
                if movedSurfaceOwner == nil {
                    movedSurfaceOwner = workspace
                }
            }
        }
        return movedSurfaceOwner
    }

    /// Rebinds bridge status to the current owner of a moved surface and removes stale badges.
    static func deliverStatus(
        _ status: ClaudeBridgeStatus,
        for route: ClaudeBridgeRoute,
        in tabManagers: [TabManager]
    ) {
        let owner = workspace(for: route, in: tabManagers)
        for manager in tabManagers {
            for workspace in manager.tabs
            where status == .inactive || workspace.id != owner?.id {
                workspace.uniConnectClaudeBridgeStatusByPanelId.removeValue(forKey: route.id)
            }
        }
        guard status != .inactive, let owner else { return }
        owner.uniConnectClaudeBridgeStatusByPanelId[route.id] = status
    }

    func deliver(event: ClaudeBridgeEvent, route: ClaudeBridgeRoute) {
        let tabManagers = tabManagersProvider()
        guard let workspace = Self.workspace(for: route, in: tabManagers) else {
            return
        }
        // A service that was already active does not emit another status transition for
        // every completion. Rebind here too so a moved surface cannot leave its badge on
        // the old workspace while the notification correctly targets the new owner.
        Self.deliverStatus(.active, for: route, in: tabManagers)
        let workspaceName = (workspace.customTitle ?? workspace.title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let windowName = (workspace.panelTitle(panelId: route.surfaceID) ?? route.windowName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let location = String.localizedStringWithFormat(
            String(
                localized: "bridge.notification.location.workspaceAndWindow",
                defaultValue: "%@ · %@"
            ),
            workspaceName.isEmpty ? route.workspaceName : workspaceName,
            windowName.isEmpty ? route.windowName : windowName
        )
        let body: String
        switch event.kind {
        case .stop:
            body = String(
                localized: "bridge.notification.completed.body",
                defaultValue: "Claude finished its response in this remote window."
            )
        case .idlePrompt:
            body = String(
                localized: "bridge.notification.idle.body",
                defaultValue: "Claude is waiting for input in this remote window."
            )
        case .sessionStart, .userPromptSubmit:
            return
        }
        notificationStore.addNotification(
            tabId: workspace.id,
            surfaceId: route.surfaceID,
            title: String(localized: "bridge.notification.title", defaultValue: "Claude Code"),
            subtitle: location,
            body: body,
            cooldownKey: "uniconnect.claude-bridge.\(route.id.uuidString).\(event.sessionCorrelation)",
            cooldownInterval: 4
        )
    }
}
