package com.unixcision.uniconnect.android.domain

/**
 * Una cuenta en «Uso por cuenta», juntando lo que dicen todos los equipos de una misma pasada.
 *
 * La misma cuenta puede estar en el Mac y en el MINIPC: las ventanas se suman, los hosts se juntan
 * (con el nombre del equipo delante), el uso es el más reciente de los dos y los históricos se
 * mezclan por fecha.
 *
 * @property seenOn dónde se vio [usage]: «Mac · Este Mac».
 * @property rows las ventanas de esta pasada que la usan, para «Dónde está».
 */
data class UsageAccount(
    val key: String,
    val provider: String,
    val displayName: String,
    val email: String?,
    val plan: String?,
    val windows: Int,
    val hosts: List<String>,
    val usage: AccountUsage?,
    val seenOn: String?,
    val history: List<UsageSample>,
    val rows: List<AccountRow>,
) {
    /** Su color en [AccountPalette.COLORS], o nulo sin email. */
    val colorIndex: Int? get() = email?.takeIf { it.isNotBlank() }?.let(AccountPalette::indexOf)
}
