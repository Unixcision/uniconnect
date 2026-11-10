import CMUXAgentLaunch
import Foundation

/// The Linux relaunch worker as bundled into the app from `linux/` at build time.
///
/// The Mac ships whatever the repository has: `relaunch_worker.py`, `resume_catalog.py` and
/// `agent_identity_hook.py` from `linux/uniconnect/`, `recovery.py` from `linux/scripts/`, and
/// `contracts/relaunch-v1/mensajes.json` are copied as resources, so a fix on Linux reaches Mac SSH windows with the next build and there is
/// no second implementation to keep in step.
struct UniConnectRelaunchWorkerScripts: Sendable {
    /// The packed worker.
    let source: RelaunchWorkerSource
    /// The catalogue's `providers` object, sent with every request.
    let catalogProviders: Data
    /// `contracts/relaunch-v1/mensajes.json`, sent whole with Claude's `start`; `nil` if missing.
    var messages: Data?

    /// Loads the bundled files, or `nil` when any of the required ones is missing.
    static func bundled(bundle: Bundle = .main) -> UniConnectRelaunchWorkerScripts? {
        func text(_ name: String) -> Data? {
            guard let url = bundle.url(forResource: name, withExtension: "py"),
                  let data = try? Data(contentsOf: url), data.count <= 512 * 1_024 else { return nil }
            return data
        }
        let messages = bundle.url(forResource: "mensajes", withExtension: "json").flatMap { try? Data(contentsOf: $0) }
        guard let catalog = text("resume_catalog"), let worker = text("relaunch_worker"),
              let hook = text("agent_identity_hook"),
              let providers = RelaunchWorkerRequest.bundledCatalogProviders() else { return nil }
        return UniConnectRelaunchWorkerScripts(
            source: RelaunchWorkerSource(
                catalogModule: String(decoding: catalog, as: UTF8.self),
                worker: String(decoding: worker, as: UTF8.self),
                identityHook: hook,
                recoveryScript: text("recovery")
            ),
            catalogProviders: providers,
            messages: messages
        )
    }
}
