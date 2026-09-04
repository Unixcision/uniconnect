import AppKit
import Foundation
import UniConnectClaudeUpdate

/// Owns the user-facing update flow while delegating all mutation to the actor state machine.
@MainActor
final class UniConnectClaudeUpdateCoordinator {
    private let targetProvider: any ClaudeUpdateTargetProviding
    private let orchestrator: ClaudeUpdateOrchestrator
    private let terminateOwnedProcesses: @Sendable () -> Void
    private var windowController: UniConnectClaudeUpdateWindowController?
    private var presentedModel: UniConnectClaudeUpdateModel?
    private var preparationTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var activeOperation: ClaudeUpdateOperation?

    init(
        targetProvider: any ClaudeUpdateTargetProviding,
        orchestrator: ClaudeUpdateOrchestrator,
        terminateOwnedProcesses: @escaping @Sendable () -> Void = {}
    ) {
        self.targetProvider = targetProvider
        self.orchestrator = orchestrator
        self.terminateOwnedProcesses = terminateOwnedProcesses
    }

    func request(_ scope: ClaudeUpdateScope) {
        if let windowController, let presentedModel {
            switch presentedModel.stage {
            case .completed, .failed:
                close(model: presentedModel)
            case .preparing, .confirmation, .running:
                windowController.showWindow(nil)
                windowController.window?.makeKeyAndOrderFront(nil)
                return
            }
        }

        let model = UniConnectClaudeUpdateModel(scope: scope)
        let controller = UniConnectClaudeUpdateWindowController(
            model: model,
            onConfirm: { [weak self] in self?.startConfirmedOperation(model: model) },
            onCancel: { [weak self] in self?.cancel(model: model) },
            onClose: { [weak self] in self?.close(model: model) }
        )
        presentedModel = model
        windowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)

        preparationTask = Task { [weak self, targetProvider] in
            do {
                let targets = try await targetProvider.targets(for: scope)
                try Task.checkCancellation()
                let plan = try ClaudeUpdatePlan(scope: scope, targets: targets)
                guard let self, self.windowController === controller else { return }
                model.plan = plan
                model.stage = .confirmation
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.windowController === controller else { return }
                model.errorMessage = Self.safeMessage(for: error)
                model.stage = .failed
            }
        }
    }

    func recoverPendingSessions() {
        guard windowController == nil else { return }
        Task { [weak self, orchestrator] in
            do {
                let outcomes = try await orchestrator.recoverPendingSessions()
                guard !outcomes.isEmpty, let self else { return }
                self.presentRecoverySummary(outcomes)
            } catch ClaudeUpdateOrchestratorError.operationAlreadyRunning {
                return
            } catch {
                guard let self else { return }
                self.presentRecoveryFailure()
            }
        }
    }

    /// Cancels UI work and synchronously terminates updater-owned child processes at app exit.
    func shutdown() {
        preparationTask?.cancel()
        preparationTask = nil
        progressTask?.cancel()
        progressTask = nil
        activeOperation?.cancel()
        activeOperation = nil
        windowController?.endSafetyModal()
        terminateOwnedProcesses()
        Task { [orchestrator] in
            await orchestrator.cancelActiveOperation()
        }
    }

    private func startConfirmedOperation(model: UniConnectClaudeUpdateModel) {
        guard model.stage == .confirmation,
              activeOperation == nil,
              let confirmedPlan = model.plan else {
            return
        }
        model.stage = .running
        progressTask = Task { [weak self, orchestrator] in
            do {
                let operation = try await orchestrator.start(confirmedPlan: confirmedPlan)
                guard let self else {
                    operation.cancel()
                    return
                }
                self.activeOperation = operation
                model.plan = operation.plan
                for await progress in operation.progress {
                    guard !Task.isCancelled else { break }
                    model.progress = progress
                }
                let summary = await operation.result()
                guard self.activeOperation?.id == operation.id else { return }
                self.activeOperation = nil
                model.summary = summary
                model.stage = .completed
                self.windowController?.endSafetyModal()
            } catch is CancellationError {
                model.errorMessage = String(
                    localized: "claudeUpdate.error.cancelledBeforeStart",
                    defaultValue: "The update was cancelled before it started."
                )
                model.stage = .failed
                self?.windowController?.endSafetyModal()
            } catch {
                model.errorMessage = Self.safeMessage(for: error)
                model.stage = .failed
                self?.windowController?.endSafetyModal()
            }
        }
        windowController?.beginSafetyModal()
    }

    private func cancel(model: UniConnectClaudeUpdateModel) {
        switch model.stage {
        case .preparing:
            preparationTask?.cancel()
            close(model: model)
        case .confirmation:
            close(model: model)
        case .running:
            guard !model.cancellationRequestedByUser else { return }
            model.cancellationRequestedByUser = true
            progressTask?.cancel()
            activeOperation?.cancel()
            // Starting the confirmed plan may arm the actor immediately before
            // returning its handle to this coordinator. Cancelling through both paths
            // closes that narrow hand-off race while preserving mandatory restoration.
            Task { [orchestrator] in
                await orchestrator.cancelActiveOperation()
            }
        case .completed, .failed:
            close(model: model)
        }
    }

    private func close(model: UniConnectClaudeUpdateModel) {
        guard model.stage != .running else { return }
        preparationTask?.cancel()
        preparationTask = nil
        progressTask?.cancel()
        progressTask = nil
        windowController?.closeWithoutCallback()
        windowController = nil
        presentedModel = nil
    }

    private func presentRecoverySummary(_ outcomes: [ClaudeUpdateOutcome]) {
        let restored = outcomes.filter { $0.status == .restored }.count
        let failed = outcomes.filter { $0.status == .failed }.count
        let alert = NSAlert()
        alert.alertStyle = failed == 0 ? .informational : .warning
        alert.messageText = String(
            localized: "claudeUpdate.recovery.title",
            defaultValue: "Claude session recovery"
        )
        let format = String(
            localized: "claudeUpdate.recovery.summary",
            defaultValue: "%1$lld restored, %2$lld still need attention."
        )
        alert.informativeText = String.localizedStringWithFormat(
            format,
            Int64(restored),
            Int64(failed)
        )
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.runModal()
    }

    private func presentRecoveryFailure() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "claudeUpdate.recovery.failureTitle",
            defaultValue: "Claude sessions still need recovery"
        )
        alert.informativeText = String(
            localized: "claudeUpdate.recovery.failureDetail",
            defaultValue: "UniConnect kept the recovery journal and will retry without starting a duplicate session."
        )
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.runModal()
    }

    private static func safeMessage(for error: Error) -> String {
        switch error {
        case ClaudeUpdatePlanError.noTargets:
            return String(
                localized: "claudeUpdate.error.noTargets",
                defaultValue: "No safely identifiable Claude window was found in this scope."
            )
        case ClaudeUpdateOrchestratorError.operationAlreadyRunning:
            return String(
                localized: "claudeUpdate.error.alreadyRunning",
                defaultValue: "Another Claude update or recovery is already running."
            )
        case ClaudeUpdateOrchestratorError.recoveryRequired:
            return String(
                localized: "claudeUpdate.error.recoveryRequired",
                defaultValue: "Pending Claude sessions must be restored before a new update can start."
            )
        case is ClaudeUpdatePlanError:
            return String(
                localized: "claudeUpdate.error.unsafePlan",
                defaultValue: "The update was stopped because two windows could not be distinguished safely."
            )
        default:
            return String(
                localized: "claudeUpdate.error.preflight",
                defaultValue: "UniConnect could not prepare a safe Claude update. No terminal input was sent."
            )
        }
    }
}
