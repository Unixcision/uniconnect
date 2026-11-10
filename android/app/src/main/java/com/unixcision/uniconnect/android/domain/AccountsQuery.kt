package com.unixcision.uniconnect.android.domain

/**
 * Cómo se está mirando «Cuentas de IA»: la ficha elegida, el buscador, la agrupación y si se
 * enseñan las ventanas sin IA.
 *
 * Por defecto, todas, por espacio y sin las ventanas sin IA (`sin_ia`, `sin_tmux`, `panel_muerto`).
 */
data class AccountsQuery(
    val chip: AccountChip = AccountChip.All,
    val search: String = "",
    val grouping: Grouping = Grouping.BY_WORKSPACE,
    val showWithoutAgent: Boolean = false,
) {
    enum class Grouping { BY_WORKSPACE, BY_ACCOUNT }
}
