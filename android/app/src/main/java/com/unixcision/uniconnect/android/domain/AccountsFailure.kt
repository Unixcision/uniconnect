package com.unixcision.uniconnect.android.domain

/**
 * Por qué no se pudo leer un equipo entero. Sus ventanas no se enseñan: nunca la lectura anterior.
 */
data class AccountsFailure(val kind: Kind, val code: String? = null, val detail: String? = null) {
    enum class Kind {
        /** No contestó a tiempo o se cortó. */
        UNREACHABLE,
        /** UniConnect está bloqueado en ese equipo (`locked`). */
        LOCKED,
        /** El equipo no sabe dar las cuentas (`method_not_found`). */
        UNSUPPORTED,
        /** Contestó con otro error del contrato. */
        REJECTED,
        /** Contestó algo que esta versión no entiende. */
        MALFORMED,
    }

    companion object {
        /** La lectura de un fallo de la llamada. */
        fun of(failure: Throwable): AccountsFailure = when (failure) {
            is MachineFailure.Rejected -> when (failure.code) {
                "locked" -> AccountsFailure(Kind.LOCKED, failure.code, failure.detail)
                "method_not_found" -> AccountsFailure(Kind.UNSUPPORTED, failure.code, failure.detail)
                else -> AccountsFailure(Kind.REJECTED, failure.code.takeIf { it.isNotBlank() }, failure.detail)
            }
            is MachineFailure.ProtocolMismatch -> AccountsFailure(Kind.MALFORMED)
            else -> AccountsFailure(Kind.UNREACHABLE)
        }
    }
}
