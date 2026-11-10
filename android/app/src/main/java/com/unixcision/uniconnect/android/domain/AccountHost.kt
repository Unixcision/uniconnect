package com.unixcision.uniconnect.android.domain

/**
 * Un host leído en una llamada a `mobile.accounts.list`: el propio equipo o una caja SSH.
 *
 * [hostKey] es `local` o `ssh:<user>@<hostname>:<port>`; [label], lo que se enseña. [state] se
 * guarda crudo: `ok`, `host_inaccesible`, `boveda_cerrada` o uno nuevo del contrato.
 */
data class AccountHost(
    val hostKey: String,
    val label: String,
    val kind: String,
    val state: String,
    val checkedAt: String?,
) {
    /** Si sus ventanas se leyeron en esta llamada. */
    val readable: Boolean get() = state == OK

    companion object {
        const val OK = "ok"
        const val UNREACHABLE = "host_inaccesible"
        const val VAULT_LOCKED = "boveda_cerrada"
    }
}
