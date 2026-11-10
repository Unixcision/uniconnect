package com.unixcision.uniconnect.android.domain

/** Una ficha de filtro de «Cuentas de IA». Solo una a la vez. */
sealed interface AccountChip {
    /** Todas las ventanas. */
    data object All : AccountChip

    /** Solo las ventanas de esta cuenta, en minúsculas. */
    data class Email(val email: String) : AccountChip

    /** Las IA sin sesión iniciada. */
    data object NoSession : AccountChip

    /**
     * Las que no se pudieron leer: `no_legible`, `desconocida`, `host_inaccesible`,
     * `sesion_no_viva` e `identidad_ambigua`, y cualquier estado que esta versión no conozca.
     */
    data object Unread : AccountChip
}

/** Una ficha con su recuento; [colorIndex] solo en las de email. */
data class AccountChipCount(val chip: AccountChip, val count: Int, val colorIndex: Int? = null)
