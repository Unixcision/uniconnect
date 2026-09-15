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
/// - **A window on a server.** The session record of a remote pane carries no conversation at all,
///   so there is nothing to give back after closing it.
/// - **A pane somebody else owns.** A supervisor that relaunches on its own terms will race this
///   one, and neither knows about the other.
struct UniConnectRelaunchClosurePolicy: Sendable {
    /// What is still missing, and for which case. Emptying it is how the refusal is lifted — with
    /// the test that proves the condition, never by deleting the check.
    static let outstandingConditions = [
        "identidad de la IA en paneles de caja SSH",
        "exclusion compartida con otros supervisores",
        "recuperacion durable de la operacion tras un corte",
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

    /// Why `key` may not be closed, or nil when it may.
    func refusal(for key: RelaunchTargetKey) -> RelaunchCause? {
        switch key.destination {
        case .local:
            return allowsLocal ? nil : .unsupported
        case .ssh:
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
                defaultValue: "Las ventanas que viven en un servidor todavía no se pueden relanzar desde aquí: falta acreditar qué IA hay en cada una. No se ha tocado ninguna."
            )
        default:
            String(
                localized: "uniconnect.relaunch.blocked",
                defaultValue: "Relanzar no está disponible para esa ventana. No se ha tocado ninguna."
            )
        }
    }
}
