import CMUXMobileCore
import CmuxSettings
import Foundation
import Observation

/// Projects the private-network host's live status for its authorization window.
@MainActor
@Observable
final class UniConnectMobileAccessViewModel {
    let access: UniConnectMobileAccessModel
    private(set) var isRunning = false
    private(set) var isBusy = false
    private(set) var endpoints: [String] = []
    private(set) var errorMessage: String?

    private let host: MobileHostService
    private let settings: UserDefaultsSettingsStore
    private let enabledKey: DefaultsKey<Bool>

    init(
        access: UniConnectMobileAccessModel,
        host: MobileHostService,
        settings: UserDefaultsSettingsStore,
        enabledKey: DefaultsKey<Bool>
    ) {
        self.access = access
        self.host = host
        self.settings = settings
        self.enabledKey = enabledKey
    }

    /// Observes host changes until the presenting view is dismissed.
    func observe() async {
        let changes = host.statusUpdates()
        await access.load()
        refresh()
        for await _ in changes {
            if Task.isCancelled { return }
            refresh()
        }
    }

    func enable() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        await settings.set(true, for: enabledKey)
        _ = await host.ensureListeningAndReady()
        refresh()
    }

    private func refresh() {
        let snapshot = host.statusSnapshot()
        isRunning = snapshot.isRunning
        endpoints = snapshot.routes.compactMap { route in
            guard route.kind == .tailscale,
                  case let .hostPort(host, port) = route.endpoint else { return nil }
            return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        }
        errorMessage = snapshot.lastErrorDescription == nil ? nil : String(
            localized: "uniconnect.mobile.access.notListening",
            defaultValue: "No se ha podido abrir el acceso privado. Comprueba que Tailscale está conectado y que el puerto está libre."
        )
    }
}
