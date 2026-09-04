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

    func deliver(event: ClaudeBridgeEvent, route: ClaudeBridgeRoute) {
        guard let workspace = tabManagersProvider()
            .lazy
            .compactMap({ manager in manager.tabs.first(where: { $0.id == route.workspaceID }) })
            .first,
              workspace.panels[route.surfaceID] != nil else {
            return
        }
        let workspaceName = workspace.title.trimmingCharacters(in: .whitespacesAndNewlines)
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
            tabId: route.workspaceID,
            surfaceId: route.surfaceID,
            title: String(localized: "bridge.notification.title", defaultValue: "Claude Code"),
            subtitle: location,
            body: body,
            cooldownKey: "uniconnect.claude-bridge.\(route.id.uuidString).\(event.sessionCorrelation)",
            cooldownInterval: 4
        )
    }
}
