import Foundation

/// Where one target of a relaunch operation stands.
///
/// Reported per target and never aggregated: "18 of 26 done" tells nobody which two need them.
public enum RelaunchTargetState: String, Sendable, Codable {
    /// Chosen by the plan, nothing done to it yet.
    case planned = "planificado"
    /// The agent is being closed. Only ``RelaunchVerb/agentRelaunch`` passes through here.
    case closing = "cerrando"
    /// The agent is being reopened on its conversation.
    case reopening = "reabriendo"
    /// The transport is being reattached.
    case reattaching = "reenganchando"
    /// The assignment is being handed to a live agent.
    case delivering = "entregando"
    /// Done, and *checked*. What is checked depends on the verb.
    case verified = "verificado"
    /// Stopped on something a person has to answer: a trust prompt, a permission, an unknown dialog.
    case needsUser = "necesita_usuario"
    /// Left out by the plan, or dropped before anything was touched.
    case skipped = "omitido"
    /// Tried and did not work.
    case failed = "fallido"
}
