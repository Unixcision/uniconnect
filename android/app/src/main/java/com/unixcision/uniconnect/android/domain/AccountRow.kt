package com.unixcision.uniconnect.android.domain

import java.util.Locale

/**
 * Una ventana de un equipo, lista para filtrarla y pintarla.
 *
 * [host] es el host de su respuesta, si la respuesta lo nombra; [hostLabel] pone el nombre del
 * equipo delante: con varios equipos, «root@…:22» a secas no dice desde dónde se leyó.
 */
data class AccountRow(val machineID: String, val machineName: String, val window: AccountWindow, val host: AccountHost?) {
    val state: AccountWindowState? get() = window.state

    /** «MINIPC · dgomezm@100.123.234.20:22». */
    val hostLabel: String get() = listOf(machineName, host?.label?.takeIf { it.isNotBlank() } ?: window.hostKey)
        .filter { it.isNotBlank() }.joinToString(" · ")

    /** El email de la cuenta en minúsculas, solo si se leyó en esta llamada (`ok`). */
    val email: String? get() = window.account?.email?.trim()?.lowercase(Locale.ROOT)
        ?.takeIf { it.isNotEmpty() && state == AccountWindowState.OK }

    /** Las que el interruptor «Ventanas sin IA» esconde cuando está apagado. */
    val withoutAgent: Boolean get() = state in WITHOUT_AGENT

    /** Las que van en «Sin leer»: las del contrato y cualquier estado que no se conozca. */
    val unread: Boolean get() = state == null || state in UNREAD

    val label: AccountLabel get() {
        val method = AccountMethod.named(window.account?.method)
        return when (state) {
            null -> AccountLabel.Unknown(window.stateWire)
            AccountWindowState.OK -> {
                val address = email
                when {
                    // Con clave de API, Bedrock, Vertex o Foundry se enseña el método, no un email. Un
                    // token de setup-token con su correo asociado es esa cuenta, y se enseña el correo.
                    method != null && (method != AccountMethod.SETUP_TOKEN || address == null) -> AccountLabel.Method(method)
                    address != null -> AccountLabel.Email(address, AccountPalette.indexOf(address))
                    else -> AccountLabel.Status(AccountStatus.NO_EMAIL, window.account?.osUser)
                }
            }
            AccountWindowState.NO_SESSION -> AccountLabel.Status(AccountStatus.NO_SESSION, window.account?.osUser)
            AccountWindowState.NOT_READABLE -> AccountLabel.Status(AccountStatus.NOT_READABLE, window.account?.osUser)
            AccountWindowState.NOT_EXPOSED -> AccountLabel.Status(AccountStatus.NOT_EXPOSED, window.account?.osUser)
            AccountWindowState.HOST_UNREACHABLE -> AccountLabel.Status(AccountStatus.HOST_UNREACHABLE)
            AccountWindowState.NO_TMUX -> AccountLabel.Status(AccountStatus.NO_TMUX)
            AccountWindowState.SESSION_NOT_ALIVE -> AccountLabel.Status(AccountStatus.SESSION_NOT_ALIVE)
            AccountWindowState.NO_AGENT -> AccountLabel.Status(AccountStatus.NO_AGENT)
            AccountWindowState.AMBIGUOUS_IDENTITY -> AccountLabel.Status(AccountStatus.AMBIGUOUS_IDENTITY)
            AccountWindowState.DEAD_PANE -> AccountLabel.Status(AccountStatus.DEAD_PANE)
        }
    }

    /** Si la fila entra con [chip]. */
    fun matches(chip: AccountChip): Boolean = when (chip) {
        AccountChip.All -> true
        is AccountChip.Email -> email == chip.email
        AccountChip.NoSession -> state == AccountWindowState.NO_SESSION
        AccountChip.Unread -> unread
    }

    /**
     * Si cada palabra de [search] está en el espacio, la ventana, el email, el equipo o el host, o
     * el usuario del sistema, sin mirar mayúsculas. Un buscador vacío deja pasar todo.
     */
    fun matches(search: String): Boolean {
        val terms = search.trim().lowercase(Locale.ROOT).split(Regex("\\s+")).filter { it.isNotEmpty() }
        if (terms.isEmpty()) return true
        val haystack = listOfNotNull(
            window.workspace, window.window, window.account?.email, machineName, host?.label, window.hostKey, window.account?.osUser,
        ).joinToString("\n").lowercase(Locale.ROOT)
        return terms.all { it in haystack }
    }

    companion object {
        private val WITHOUT_AGENT = setOf(AccountWindowState.NO_AGENT, AccountWindowState.NO_TMUX, AccountWindowState.DEAD_PANE)
        private val UNREAD = setOf(
            AccountWindowState.NOT_READABLE, AccountWindowState.NOT_EXPOSED, AccountWindowState.HOST_UNREACHABLE,
            AccountWindowState.SESSION_NOT_ALIVE, AccountWindowState.AMBIGUOUS_IDENTITY,
        )
    }
}
