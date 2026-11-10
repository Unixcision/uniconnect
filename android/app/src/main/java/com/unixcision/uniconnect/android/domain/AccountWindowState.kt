package com.unixcision.uniconnect.android.domain

/**
 * En qué está la cuenta de una ventana (`accounts.v1`): la primera regla del contrato que se cumple.
 *
 * Viaja como texto; [named] es su lectura en esta versión y nulo si no la conoce. Un estado que no
 * se conoce nunca se toma por `ok`: se cuenta como «sin leer».
 */
enum class AccountWindowState(val wire: String) {
    /** La cuenta se leyó en esta llamada. */
    OK("ok"),
    /** La IA no tiene sesión iniciada. */
    NO_SESSION("sin_sesion"),
    /** Su configuración no se puede leer con el usuario de la sonda (nunca sudo). */
    NOT_READABLE("no_legible"),
    /** UniConnect no sabe dónde guarda esa IA su cuenta. */
    NOT_EXPOSED("desconocida"),
    /** El host no contestó o tiene la bóveda cerrada: sin cuenta, nunca la última conocida. */
    HOST_UNREACHABLE("host_inaccesible"),
    /** La ventana no tiene sesión tmux. */
    NO_TMUX("sin_tmux"),
    /** La sonda no vio la sesión tmux de la ventana. */
    SESSION_NOT_ALIVE("sesion_no_viva"),
    /** En la ventana no corre ninguna IA. */
    NO_AGENT("sin_ia"),
    /** No se sabe con certeza qué IA es. */
    AMBIGUOUS_IDENTITY("identidad_ambigua"),
    /** El panel de tmux está muerto. */
    DEAD_PANE("panel_muerto");

    companion object {
        fun named(raw: String?): AccountWindowState? = entries.firstOrNull { it.wire == raw }
    }
}
