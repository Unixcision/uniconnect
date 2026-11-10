package com.unixcision.uniconnect.android.domain

/**
 * Lo que dijo Codex al gastar un reseteo gratis (`outcome`, §5).
 *
 * [named] da [UNKNOWN] para un valor nuevo: la pantalla lo enseña tal cual en vez de dar por hecho
 * que salió bien.
 */
enum class CodexResetOutcome(val wire: String) {
    /** Hecho: los límites de la cuenta vuelven a empezar. */
    RESET("reset"),
    /** No había nada que resetear, y no se ha gastado ninguno. */
    NOTHING_TO_RESET("nothingToReset"),
    /** La cuenta ya no tiene reseteos gratis. */
    NO_CREDIT("noCredit"),
    /** Esa misma clave ya lo había aplicado: un reintento no gasta otro. */
    ALREADY_REDEEMED("alreadyRedeemed"),
    UNKNOWN("");

    companion object {
        fun named(raw: String?): CodexResetOutcome = entries.firstOrNull { it != UNKNOWN && it.wire == raw } ?: UNKNOWN
    }
}
