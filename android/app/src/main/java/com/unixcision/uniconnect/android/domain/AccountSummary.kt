package com.unixcision.uniconnect.android.domain

/**
 * Una cuenta de un equipo (`accounts[]`, §3.1): proveedor y email, en cuántas ventanas está, el uso
 * más reciente visto en cualquiera de ellas y su histórico de 7 días.
 *
 * [key] es `<proveedor>:<email>`. El histórico es lo único que el escritorio recuerda entre
 * llamadas, y se enseña como tal, con sus fechas.
 */
data class AccountSummary(
    val key: String,
    val provider: String,
    val displayName: String,
    val email: String?,
    val plan: String?,
    val organization: String?,
    val windows: Int,
    val hostKeys: List<String>,
    val usage: AccountUsage?,
    val history: List<UsageSample>,
)
