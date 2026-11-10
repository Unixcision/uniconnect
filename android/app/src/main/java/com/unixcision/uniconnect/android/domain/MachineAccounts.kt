package com.unixcision.uniconnect.android.domain

/**
 * El resultado de leer las cuentas de un equipo en una pasada: su respuesta, o por qué no la hay.
 *
 * Siempre de la misma pasada. Un equipo que falla se queda sin [report]: no hereda el de la vez
 * anterior, porque una cuenta vieja pintada como actual es justo lo que hay que evitar.
 */
data class MachineAccounts(
    val machineID: String,
    val machineName: String,
    val report: AccountsReport?,
    val failure: AccountsFailure? = null,
)
