import CMUXAgentLaunch
import Foundation

/// The one way into relaunching and updating agents, whoever asked.
///
/// Menu item, context menu, palette, rail, phone: all of them arrive here, and through **one
/// instance** owned by ``UniConnectCoordinator`` (`relaunchService`). A second path would be a
/// second set of rules about what is safe, and the rules are the whole feature; a second instance
/// would be a second idea of which panes are already being handled.
///
/// Local windows are closed and reopened by this Mac; SSH windows by the Linux worker on their box
/// (``UniConnectRelaunchRemoteExecutor``). `agent.update` runs `claude update` once per installation
/// before closing anything of it, and an installation whose update fails keeps all its windows.
@MainActor
final class UniConnectRelaunchCoordinator {
    /// How many windows a request has to touch before it is shown first.
    ///
    /// Counted in **windows and not in scopes**: a box with one window does not deserve a question,
    /// and a machine with twenty does, even though the same menu item produced both. On a phone the
    /// difference between "this box" and "everything" is one stray tap and twenty-six restarted
    /// agents. Anything that will be interrupted, kept or cost something is shown regardless.
    static let confirmationThreshold = 5

    /// A window set aside, with the panel it belongs to when there is one.
    struct ExcludedWindow {
        let panelID: UUID?
        let exclusion: RelaunchPlan.Exclusion
    }

    /// What a request would do, handed back before it does it.
    struct Preview {
        let verb: RelaunchVerb
        var options: RelaunchUpdateOptions
        let targets: [UniConnectRelaunchExecutor.Target]
        let excluded: [ExcludedWindow]

        var exclusions: [RelaunchPlan.Exclusion] { excluded.map(\.exclusion) }

        init(
            verb: RelaunchVerb = .agentRelaunch,
            options: RelaunchUpdateOptions = .unchanged,
            targets: [UniConnectRelaunchExecutor.Target],
            excluded: [ExcludedWindow]
        ) {
            self.verb = verb
            self.options = options
            self.targets = targets
            self.excluded = excluded
        }

        /// A preview whose exclusions are not tied to any panel (refusals, recovered operations).
        init(
            verb: RelaunchVerb = .agentRelaunch,
            options: RelaunchUpdateOptions = .unchanged,
            targets: [UniConnectRelaunchExecutor.Target],
            exclusions: [RelaunchPlan.Exclusion]
        ) {
            self.init(
                verb: verb, options: options, targets: targets,
                excluded: exclusions.map { ExcludedWindow(panelID: nil, exclusion: $0) }
            )
        }

        /// Whether this should be shown to a person before it runs.
        ///
        /// Always for an update (it may change model and effort), for many windows, and for any
        /// window that will be interrupted, keeps monitors or a draft, or gets a message.
        var needsConfirmation: Bool {
            verb == .agentUpdate
                || targets.count >= UniConnectRelaunchCoordinator.confirmationThreshold
                || targets.contains { target in
                    target.notes.active || (target.notes.background ?? 0) > 0
                        || target.notes.draft == true || target.notes.message == true
                }
        }

        /// The tokens the post-reopen messages will make the agents reread, all targets together.
        var estimatedTokens: Int {
            targets.reduce(0) { $0 + $1.notes.estimatedTokens }
        }

        /// Whether any target reports a cost estimate at all.
        var reportsCost: Bool {
            verb == .agentUpdate || targets.contains { $0.notes.message != nil }
        }
    }

    /// Reads the current state of the boxes, for SSH sightings.
    typealias RemoteSighting = (UUID) -> UniConnectRelaunchInventory.RemoteSighting?

    private let machineID: String
    private let dialects: RelaunchDialects
    private let remoteSighting: RemoteSighting
    private let executor: UniConnectRelaunchExecutor
    private let remoteWorker: UniConnectRelaunchRemoteWorker?
    private let remoteExecutor: UniConnectRelaunchRemoteExecutor?
    private let closurePolicy: UniConnectRelaunchClosurePolicy
    private let localClaude: UniConnectRelaunchLocalClaude?
    private let localInstallation: UniConnectRelaunchLocalInstallation?
    /// Panes being closed and reopened right now, by desktop or phone alike.
    private var inFlightPanes: Set<String> = []

    init(
        machineID: String,
        dialects: RelaunchDialects = .known,
        remoteSighting: @escaping RemoteSighting = { _ in nil },
        executor: UniConnectRelaunchExecutor = UniConnectRelaunchExecutor(),
        remoteWorker: UniConnectRelaunchRemoteWorker? = nil,
        remoteExecutor: UniConnectRelaunchRemoteExecutor? = nil,
        closurePolicy: UniConnectRelaunchClosurePolicy = .current,
        localClaude: UniConnectRelaunchLocalClaude? = nil,
        localInstallation: UniConnectRelaunchLocalInstallation? = nil
    ) {
        self.machineID = machineID
        self.dialects = dialects
        self.remoteSighting = remoteSighting
        self.executor = executor
        self.remoteWorker = remoteWorker
        self.remoteExecutor = remoteExecutor ?? remoteWorker.map { UniConnectRelaunchRemoteExecutor(worker: $0) }
        self.closurePolicy = closurePolicy
        self.localClaude = localClaude
        self.localInstallation = localInstallation
    }

    /// The host of this Mac's installation, as target keys spell it.
    var localHost: String { RelaunchTargetKey.Destination.local(machineID: machineID).text }

    /// Looks at `workspaces` without closing anything.
    ///
    /// SSH windows are inspected by the worker on their box (read-only), box by box in parallel.
    ///
    /// - Parameters:
    ///   - workspaces: The boxes in scope.
    ///   - verb: `agent.relaunch` or `agent.update`.
    ///   - options: `agent.update`'s model and effort.
    ///   - onlyPanels: A window scope; nothing outside it is inspected.
    /// - Returns: The targets and the exclusions, each with its cause.
    func preview(
        workspaces: [Workspace],
        verb: RelaunchVerb = .agentRelaunch,
        options: RelaunchUpdateOptions = .unchanged,
        onlyPanels: Set<UUID>? = nil
    ) async -> Preview {
        let inventory = UniConnectRelaunchInventory(
            machineID: machineID, dialects: dialects, remoteSighting: remoteSighting
        )
        let reading = inventory.read(workspaces: workspaces, verb: verb, onlyPanels: onlyPanels)
        var excluded = reading.excluded
        var targets = await inspectLocal(reading.items.map(\.target), verb: verb, excluded: &excluded)

        let remote = await inspectRemote(reading.remote, verb: verb, options: options)
        targets += remote.targets
        excluded += remote.excluded

        // La política de cierre en el PLAN, no solo en el resultado: ofrecer como «planificado»
        // lo que después se omitiría es prometer un trabajo que no se va a hacer.
        var admitted: [UniConnectRelaunchExecutor.Target] = []
        for target in targets {
            if let cause = closurePolicy.refusal(for: target) {
                excluded.append(.init(panelID: target.panelID, exclusion: .init(label: target.label, cause: cause)))
            } else {
                admitted.append(target)
            }
        }
        return Preview(verb: verb, options: options, targets: admitted, excluded: excluded)
    }

    /// Proves each local Claude from its process and session file, and checks its installation.
    private func inspectLocal(
        _ items: [UniConnectRelaunchExecutor.Target],
        verb: RelaunchVerb,
        excluded: inout [ExcludedWindow]
    ) async -> [UniConnectRelaunchExecutor.Target] {
        guard let localClaude else { return items }
        var targets: [UniConnectRelaunchExecutor.Target] = []
        var installations: [String: UniConnectRelaunchLocalInstallation.Status] = [:]
        for var target in items {
            guard target.provider == "claude" else {
                targets.append(target)
                continue
            }
            switch await localClaude.inspect(socket: target.socket, session: target.session, verb: verb) {
            case let .excluded(cause):
                excluded.append(.init(panelID: target.panelID, exclusion: .init(label: target.label, cause: cause)))
            case let .proof(proof, notes):
                // Antes de cerrar nada de una instalación, su login: sin él la ventana vuelve inservible.
                if let launcherPath = proof.launcherPath, let localInstallation {
                    if installations[launcherPath] == nil {
                        installations[launcherPath] = await localInstallation.status(launcherPath: launcherPath, path: proof.searchPath)
                    }
                    guard installations[launcherPath]?.loggedIn == true else {
                        excluded.append(.init(panelID: target.panelID, exclusion: .init(label: target.label, cause: .notLoggedIn)))
                        continue
                    }
                }
                target.route = .localClaude(proof)
                target.notes = notes
                if verb == .agentUpdate, let launcherPath = proof.launcherPath {
                    target.notes.installed = installations[launcherPath]?.version
                }
                targets.append(target)
            }
        }
        return targets
    }

    /// Asks each SSH box's worker about its windows.
    private func inspectRemote(
        _ candidates: [UniConnectRelaunchInventory.RemoteCandidate],
        verb: RelaunchVerb,
        options: RelaunchUpdateOptions
    ) async -> (targets: [UniConnectRelaunchExecutor.Target], excluded: [ExcludedWindow]) {
        guard !candidates.isEmpty else { return ([], []) }
        guard let worker = remoteWorker else {
            return ([], candidates.map { .init(panelID: $0.panelID, exclusion: .init(label: $0.label, cause: .unsupported)) })
        }
        let boxes = Dictionary(grouping: candidates, by: \.credentialID)
        let inspected = await withTaskGroup(of: [RemoteInspection].self) { group in
            for (credentialID, windows) in boxes {
                group.addTask {
                    await Self.inspectBox(credentialID: credentialID, windows: windows, worker: worker, verb: verb, options: options)
                }
            }
            var all: [RemoteInspection] = []
            for await box in group { all += box }
            return all
        }

        // Dos ventanas sobre la misma conversación en el mismo destino: reanudar abriría la rama de
        // la otra, así que ninguna de las dos entra.
        var holders: [String: Int] = [:]
        for case let .target(target, effectiveID?) in inspected {
            holders[target.key.destination.text + "|" + effectiveID.lowercased(), default: 0] += 1
        }
        var targets: [UniConnectRelaunchExecutor.Target] = []
        var excluded: [ExcludedWindow] = []
        for item in inspected {
            switch item {
            case let .target(target, effectiveID):
                if let effectiveID, (holders[target.key.destination.text + "|" + effectiveID.lowercased()] ?? 0) > 1 {
                    excluded.append(.init(panelID: target.panelID, exclusion: .init(label: target.label, cause: .sharedConversation)))
                } else {
                    targets.append(target)
                }
            case let .excluded(window):
                excluded.append(window)
            }
        }
        targets.sort { $0.label < $1.label }
        return (targets, excluded)
    }

    /// One SSH window after its box answered.
    private enum RemoteInspection: Sendable {
        case target(UniConnectRelaunchExecutor.Target, effectiveID: String?)
        case excluded(ExcludedWindow)
    }

    /// Inspects the windows of one box, one SSH call at a time so a box is never flooded.
    nonisolated private static func inspectBox(
        credentialID: UUID,
        windows: [UniConnectRelaunchInventory.RemoteCandidate],
        worker: UniConnectRelaunchRemoteWorker,
        verb: RelaunchVerb,
        options: RelaunchUpdateOptions
    ) async -> [RemoteInspection] {
        func excludeAll(_ cause: RelaunchCause) -> [RemoteInspection] {
            windows.map { .excluded(.init(panelID: $0.panelID, exclusion: .init(label: $0.label, cause: cause))) }
        }
        guard let destination = await worker.destination(credentialID: credentialID),
              let catalog = await worker.catalogProviders() else { return excludeAll(.noCredential) }

        var results: [RemoteInspection] = []
        for window in windows {
            let request = RelaunchWorkerRequest(
                action: .inspect, session: window.session, socket: window.socket, provider: window.provider,
                windowID: window.panelID.uuidString.lowercased(), catalogProviders: catalog, verb: verb,
                options: verb == .agentUpdate ? options : nil
            )
            func exclude(_ cause: RelaunchCause) {
                results.append(.excluded(.init(panelID: window.panelID, exclusion: .init(label: window.label, cause: cause))))
            }
            switch await worker.call(request, credentialID: credentialID) {
            case let .unavailable(cause):
                exclude(cause)
            case let .reply(reply):
                if let error = reply.error {
                    exclude(RelaunchCause(rawValue: error) ?? .unknownDialog)
                    continue
                }
                guard let proof = RelaunchWorkerProof(reply: reply) else {
                    exclude(.hostUnreachable)
                    continue
                }
                var notes = proof.notes
                if verb != .agentUpdate {
                    // La versión solo se enseña cuando se va a cambiar.
                    notes.version = nil
                    notes.installed = nil
                }
                let key = RelaunchTargetKey(
                    destination: destination, tmuxServer: window.socket,
                    pane: proof.pane ?? window.session, generation: proof.generation
                )
                let target = UniConnectRelaunchExecutor.Target(
                    key: key, label: window.label, provider: window.provider,
                    socket: window.socket, session: window.session, previousArgv: [],
                    panelID: window.panelID,
                    route: .ssh(.init(
                        credentialID: credentialID, session: window.session, socket: window.socket,
                        windowID: window.panelID.uuidString.lowercased(), proof: proof.raw,
                        launcher: proof.launcher
                    )),
                    notes: notes
                )
                results.append(.target(target, effectiveID: proof.effectiveID))
            }
        }
        return results
    }

    /// Runs a previewed request, reporting each window on its own.
    ///
    /// Targets are walked one at a time on purpose. Closing twenty-six agents at once would race
    /// them through the same questions, and a question answered for the wrong pane is how a session
    /// dies. A pane another request is already handling is reported as ``RelaunchCause/duplicate``
    /// and left alone. With `agent.update`, each installation is updated once before any of its
    /// windows is closed; if that fails its windows end ``RelaunchCause/updateFailed``, untouched.
    ///
    /// - Parameters:
    ///   - preview: What was confirmed.
    ///   - operationID: The operation; it keys the journals on SSH destinations.
    ///   - progress: Told the current results and updates whenever a target moves.
    /// - Returns: The finished operation.
    func run(
        _ preview: Preview,
        operationID: UUID = UUID(),
        progress: (@MainActor ([RelaunchOperation.Result], [RelaunchInstallationUpdate]) -> Void)? = nil
    ) async -> RelaunchOperation {
        ledgers[operationID] = Ledger(
            results: preview.targets.map { .init(key: $0.key, state: .planned, provider: $0.provider) },
            progress: progress
        )
        defer { ledgers[operationID] = nil }
        var updatedInstallations: [String: RelaunchInstallationUpdate] = [:]

        for (index, target) in preview.targets.enumerated() {
            if preview.verb == .agentUpdate {
                let installation = installationKey(of: target)
                if updatedInstallations[installation] == nil {
                    let update = await updateInstallation(of: target)
                    updatedInstallations[installation] = update
                    appendUpdate(update, in: operationID)
                }
                if updatedInstallations[installation]?.state == .failed {
                    // Nada de esa instalación se cierra si no se pudo actualizar.
                    setResult(.init(key: target.key, state: .skipped, cause: .updateFailed, provider: target.provider),
                              at: index, in: operationID)
                    continue
                }
            }

            let pane = target.key.paneIdentity
            guard inFlightPanes.insert(pane).inserted else {
                setResult(.init(key: target.key, state: .skipped, cause: .duplicate), at: index, in: operationID)
                continue
            }
            let result: RelaunchOperation.Result
            switch target.route {
            case .local:
                result = await executor.relaunch(target)
            case let .localClaude(proof):
                if let localClaude {
                    result = await localClaude.relaunch(
                        key: target.key, socket: target.socket, session: target.session,
                        proof: proof, verb: preview.verb, options: preview.options
                    )
                } else {
                    result = .init(key: target.key, state: .skipped, cause: .unsupported)
                }
            case let .ssh(remote):
                if let remoteExecutor {
                    result = await remoteExecutor.relaunch(
                        target, remote: remote, verb: preview.verb, options: preview.options,
                        operationID: operationID,
                        updatedTo: updatedInstallations[installationKey(of: target)]?.to,
                        progress: { [weak self] partial in
                            await self?.setResult(partial, at: index, in: operationID)
                        }
                    )
                } else {
                    result = .init(key: target.key, state: .skipped, cause: .unsupported)
                }
            }
            inFlightPanes.remove(pane)
            setResult(result, at: index, in: operationID)
        }
        let ledger = ledgers[operationID]
        return RelaunchOperation(
            operationID: operationID,
            verb: preview.verb,
            recovered: false,
            results: ledger?.results ?? [],
            updates: ledger?.updates ?? []
        )
    }

    /// The live state of a running operation.
    private struct Ledger {
        var results: [RelaunchOperation.Result]
        var updates: [RelaunchInstallationUpdate] = []
        let progress: (@MainActor ([RelaunchOperation.Result], [RelaunchInstallationUpdate]) -> Void)?
    }

    private var ledgers: [UUID: Ledger] = [:]

    private func setResult(_ result: RelaunchOperation.Result, at index: Int, in operationID: UUID) {
        guard var ledger = ledgers[operationID], ledger.results.indices.contains(index) else { return }
        ledger.results[index] = result
        ledgers[operationID] = ledger
        ledger.progress?(ledger.results, ledger.updates)
    }

    private func appendUpdate(_ update: RelaunchInstallationUpdate, in operationID: UUID) {
        guard var ledger = ledgers[operationID] else { return }
        ledger.updates.append(update)
        ledgers[operationID] = ledger
        ledger.progress?(ledger.results, ledger.updates)
    }

    /// One installation per destination machine and user: this Mac, or one SSH credential.
    private func installationKey(of target: UniConnectRelaunchExecutor.Target) -> String {
        switch target.route {
        case .local: localHost
        case let .localClaude(proof): localHost + "|" + (proof.launcherPath ?? proof.launcher)
        case let .ssh(remote): "ssh-credential:" + remote.credentialID.uuidString + "|" + (remote.launcher ?? "")
        }
    }

    /// Runs `claude update` for the installation of `target`.
    private func updateInstallation(of target: UniConnectRelaunchExecutor.Target) async -> RelaunchInstallationUpdate {
        switch target.route {
        case .local:
            return RelaunchInstallationUpdate(host: localHost, state: .failed, from: nil, to: nil)
        case let .localClaude(proof):
            guard let localInstallation, let launcherPath = proof.launcherPath else {
                return RelaunchInstallationUpdate(host: localHost, state: .failed, from: nil, to: nil)
            }
            return await localInstallation.update(launcherPath: launcherPath, path: proof.searchPath, host: localHost)
        case let .ssh(remote):
            let host = target.key.destination.text
            guard let remoteWorker, let launcher = remote.launcher,
                  let catalog = await remoteWorker.catalogProviders() else {
                return RelaunchInstallationUpdate(host: host, state: .failed, from: nil, to: nil)
            }
            let request = RelaunchWorkerRequest(
                action: .update, session: remote.session, socket: remote.socket, provider: target.provider,
                windowID: remote.windowID, catalogProviders: catalog, launcher: launcher
            )
            return await remoteWorker.update(request, credentialID: remote.credentialID, host: host)
        }
    }
}
