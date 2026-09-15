import Foundation

/// Whether this build is allowed to close a running agent, and why not when it is not.
///
/// Closing an agent is the one irreversible thing a relaunch does. Everything else — reading a
/// pane, listing windows, drawing a plan — can be repeated at no cost; a close cannot, and on
/// 15-09-2026 one took a live conversation with it and then reported the window as untouched.
///
/// So the block lives **here, in code**, and not in an agreement written down somewhere. A
/// paragraph in a coordination document saying "we keep closure blocked" is not a guard: the
/// button is still wired to the executor, and the executor still closes. This type is what makes
/// the sentence true, and its default is the safe one.
struct UniConnectRelaunchClosurePolicy: Sendable {
    /// What is still missing before this build may close an agent.
    ///
    /// Each entry is a condition of admission agreed across the three surfaces, not a wish list.
    /// The relaunch is allowed again by emptying this, one condition at a time, with the test that
    /// proves it — never by deleting the check.
    static let outstandingConditions = [
        // El ejecutor recibe `previousArgv: []`, asi que las opciones con las que arranco la
        // ventana no vuelven: relanzar cambiaria en silencio lo que la IA puede hacer.
        "opciones de arranque",
        // Nada impide que otro creador (un supervisor, otro equipo) este actuando sobre el mismo
        // panel mientras se cierra.
        "exclusion compartida entre creadores",
        // Si la respuesta se pierde despues de cerrar, no hay forma de retomar la misma operacion
        // en vez de relanzar otra vez.
        "recuperacion durable de la operacion",
        // Hoy la identidad es PID + hora de arranque. Eso distingue un proceso de otro, pero no
        // acredita que *ese* proceso sea el agente de *esta* conversacion.
        "identidad nativa vinculada al proceso",
        // Nadie comprueba que quien pide el relanzado tenga autoridad sobre el panel, ni que otro
        // duenyo no la tenga ya.
        "autoridad sobre el objetivo",
        // Verificar hoy es «hay un proceso distinto y la pantalla parece lista». Falta comprobar
        // que vuelve la misma conversacion y con la configuracion que tenia.
        "verificacion de conversacion y configuracion del proceso nuevo",
    ]

    /// Whether closing is permitted. Nil conditions remaining means it is.
    let allowsClosing: Bool

    /// The policy this build ships with: no closing until the conditions above are met.
    static let current = UniConnectRelaunchClosurePolicy(allowsClosing: outstandingConditions.isEmpty)

    /// A policy that permits closing, for tests that exercise the sequence itself.
    static let permissive = UniConnectRelaunchClosurePolicy(allowsClosing: true)

    /// What to tell somebody who asked for a relaunch they cannot have yet.
    ///
    /// The conditions are interpolated into a localized format rather than concatenated into one,
    /// so the sentence stays translatable while the list it names keeps living in code.
    var explanation: String {
        String(
            format: String(
                localized: "uniconnect.relaunch.blocked",
                defaultValue: "Relanzar todavía no está disponible: falta %@. No se ha tocado ninguna ventana."
            ),
            Self.localizedConditions
        )
    }

    /// The outstanding conditions, in the reader's language and joined as a sentence.
    private static var localizedConditions: String {
        outstandingConditions
            .map { condition in
                switch condition {
                case "opciones de arranque":
                    String(localized: "uniconnect.relaunch.blocked.argv", defaultValue: "recuperar las opciones de arranque")
                case "exclusion compartida entre creadores":
                    String(localized: "uniconnect.relaunch.blocked.exclusion", defaultValue: "la exclusión compartida entre quienes pueden abrir ventanas")
                case "recuperacion durable de la operacion":
                    String(localized: "uniconnect.relaunch.blocked.recovery", defaultValue: "poder retomar la misma operación tras un corte")
                case "identidad nativa vinculada al proceso":
                    String(localized: "uniconnect.relaunch.blocked.identity", defaultValue: "acreditar que el proceso es el de esta conversación")
                case "autoridad sobre el objetivo":
                    String(localized: "uniconnect.relaunch.blocked.authority", defaultValue: "comprobar quién manda sobre la ventana")
                case "verificacion de conversacion y configuracion del proceso nuevo":
                    String(localized: "uniconnect.relaunch.blocked.verification", defaultValue: "verificar que vuelve la misma conversación con su configuración")
                default:
                    condition
                }
            }
            .formatted(.list(type: .and))
    }
}
