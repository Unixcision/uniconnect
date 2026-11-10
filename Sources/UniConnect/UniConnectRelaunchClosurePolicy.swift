import CMUXAgentLaunch
import Foundation

/// Whether this build may close a running agent, decided per target rather than once for all.
///
/// Closing an agent is the one irreversible thing a relaunch does, and on 15-09-2026 one took a
/// live conversation with it and then reported the window as untouched. So the block lives **here,
/// in code**, and not in an agreement written down somewhere: the button is wired to the executor
/// and the executor closes, so a paragraph saying "we keep closure blocked" guards nothing.
///
/// What it does *not* do is block everything out of caution. Doing this by hand to twenty-six
/// windows works, and the steps are the same ones the executor runs — read the pane, close it, read
/// the identifier the agent prints on its way out, type it back with the flags it had, check a new
/// process is there. A local window is exactly that case and is allowed. What is still refused is
/// the case where those steps are **not** enough:
///
/// - **A window on a server that the worker did not prove.** A remote pane is closed only by the
///   Linux worker on its own box, and only after its `inspect` proved the agent, the conversation
///   and the options. A remote key without that proof has nothing to give back after closing it.
/// What it does **not** check yet, said here so nobody reads a promise into it: whether something
/// else owns the pane. A supervisor that relaunches on its own terms would race this one and
/// neither would know about the other. On this desktop there is no such supervisor — the local
/// windows are tmux sessions UniConnect opened itself — which is why a local window is allowed
/// while that check is still missing; it is a reason, not a substitute.
struct UniConnectRelaunchClosurePolicy: Sendable {
    /// What is still missing, and for which case. Emptying it is how the refusal is lifted — with
    /// the test that proves the condition, never by deleting the check.
    static let outstandingConditions = [
        "exclusion compartida con otros supervisores en ventanas locales",
        "recuperacion durable de la operacion local tras un corte",
    ]

    /// Whether a destination this build understands well enough may be closed.
    private let allowsLocal: Bool

    /// The policy this build ships with.
    static let current = UniConnectRelaunchClosurePolicy(allowsLocal: true)

    /// A policy that refuses everything, for tests that assert nothing is touched.
    static let refusing = UniConnectRelaunchClosurePolicy(allowsLocal: false)

    init(allowsLocal: Bool) {
        self.allowsLocal = allowsLocal
    }

    /// Why `target` may not be closed, or nil when it may.
    func refusal(for target: UniConnectRelaunchExecutor.Target) -> RelaunchCause? {
        switch (target.key.destination, target.route) {
        case (.local, .local), (.local, .localClaude):
            return allowsLocal ? nil : .unsupported
        case (.ssh, .ssh):
            // Lo cierra el trabajador en su destino, y solo sobre lo que su inspect acreditó.
            return allowsLocal ? nil : .unsupported
        default:
            // Sin conversación acreditada no hay nada que devolver después de cerrar.
            return .unsupported
        }
    }

    /// What to tell somebody about a target this build will not close.
    func explanation(for cause: RelaunchCause) -> String {
        switch cause {
        case .unsupported:
            String(
                localized: "uniconnect.relaunch.blocked.remote",
                defaultValue: "Relanzar no está disponible para estas ventanas en este equipo. No se ha tocado ninguna."
            )
        default:
            String(
                localized: "uniconnect.relaunch.blocked",
                defaultValue: "Relanzar no está disponible para esa ventana. No se ha tocado ninguna."
            )
        }
    }
}
