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
    /// Accepted, then cancelled before anything was sent to it. Nothing was touched.
    ///
    /// Its own cause and not a failure: a target that never left the queue has a different answer
    /// from one that was tried and did not work, and retrying them means different things.
    case notSent = "no_enviado"
    /// The target changed between the plan and the execution.
    case generationChanged = "generacion_cambiada"
    /// The machine did not answer.
    case hostUnreachable = "host_inaccesible"
    /// The same target is already being handled elsewhere.
    case duplicate = "duplicado"
    /// The machine does not announce `relaunch.v1`, or the provider has no such verb.
    case unsupported = "no_soportado"
    /// The window has no agent running: it is at a shell, or stopped. There is nothing to relaunch,
    /// and starting one that was not there is not "leave it as it was".
    case noAgent = "sin_ia"
    /// The agent has tasks or monitors running. Closing it would stop them or strand them outside
    /// the conversation, so it is not closed: they are saved first or allowed to finish.
    case backgroundTasks = "tareas_de_fondo"
    /// This machine does not know how to relaunch that agent in that kind of window.
    case providerUnsupported = "proveedor_no_soportado"
    /// The window is not inside a tmux session, so there is no session to keep.
    case noTmux = "sin_tmux"
    /// The SSH box's credential is not available right now (locked vault, deleted record).
    case noCredential = "sin_credencial"
    /// The server does not let its processes be inspected (no `/proc` or `pidfd`).
    case destinationNotLinux = "destino_no_linux"
    /// The window's folder no longer exists.
    case missingFolder = "carpeta_inexistente"
    /// The agent's program is not installed or cannot be executed.
    case missingBinary = "binario_no_encontrado"
    /// Codex is not paused by a usage limit: there is nothing to continue.
    case notPaused = "sin_pausa"
    /// The tmux session holds other panes or windows, so it is never killed.
    case sharedSession = "sesion_compartida"
    /// Claude is not logged in on that machine; reopening would leave a useless window.
    case notLoggedIn = "sin_login"
    /// Another live window has the same conversation open; resuming would follow its branch.
    case sharedConversation = "conversacion_compartida"
    /// `claude update` failed on that installation, so none of its windows were closed.
    case updateFailed = "actualizacion_fallida"
}
