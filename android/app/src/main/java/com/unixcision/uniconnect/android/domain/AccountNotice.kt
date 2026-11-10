package com.unixcision.uniconnect.android.domain

/** Un aviso de arriba de «Cuentas de IA»: algo que no se pudo leer y por eso no se enseña. */
sealed interface AccountNotice {
    /** Un equipo entero no contestó: sus ventanas no salen. */
    data class MachineFailed(val machineName: String, val failure: AccountsFailure) : AccountNotice

    /** Un host de un equipo no se pudo leer; [state] crudo (`host_inaccesible`, `boveda_cerrada`, …). */
    data class HostUnreadable(val hostLabel: String, val state: String) : AccountNotice
}
