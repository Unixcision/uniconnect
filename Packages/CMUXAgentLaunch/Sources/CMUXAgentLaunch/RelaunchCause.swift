import Foundation

/// Why a target was skipped, needs a person, or failed.
///
/// The identifier travels; the sentence the reader sees is the client's, in its own language. A
/// cause on one target is **not** an error of the call: twenty-five targets can succeed while one
/// waits for someone to answer a trust prompt.
public enum RelaunchCause: String, Sendable, Codable, CaseIterable, Error {
    /// Which conversation this is could not be established. Nothing is closed on a guess.
    case ambiguousIdentity = "identidad_ambigua"
    /// The screen showed something unrecognised. Nothing is answered blindly.
    case unknownDialog = "dialogo_desconocido"
    /// The agent asked whether the folder is trusted. A person answers that.
    case folderTrust = "confianza_carpeta"
    /// The agent asked for permissions. A person answers that.
    case permissions = "permisos"
    /// Nobody holds resolvable authority over this target, or another executor does.
    case noAuthority = "sin_autoridad"
    /// The target changed between the plan and the execution.
    case generationChanged = "generacion_cambiada"
    /// The machine did not answer.
    case hostUnreachable = "host_inaccesible"
    /// The same target is already being handled elsewhere.
    case duplicate = "duplicado"
    /// The machine does not announce `relaunch.v1`, or the provider has no such verb.
    case unsupported = "no_soportado"
}
