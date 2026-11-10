package com.unixcision.uniconnect.android.domain

/**
 * Cómo se está mirando «Cuentas de IA»: la IA y la ficha de cuenta elegidas, el buscador, la
 * agrupación y si se enseñan las ventanas sin IA.
 *
 * Por defecto, todas las IA y todas las cuentas, por espacio y sin las ventanas sin IA (`sin_ia`,
 * `sin_tmux`, `panel_muerto`). [provider] es un `agent.provider`, o nulo para todas.
 */
data class AccountsQuery(
    val chip: AccountChip = AccountChip.All,
    val search: String = "",
    val grouping: Grouping = Grouping.BY_WORKSPACE,
    val showWithoutAgent: Boolean = false,
    val provider: String? = null,
) {
    enum class Grouping { BY_WORKSPACE, BY_ACCOUNT, BY_AGENT }
}
