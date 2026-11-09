package com.unixcision.uniconnect.android.domain

/**
 * El plan de un equipo dentro de una petición, que puede abarcar varios.
 *
 * [plan] es nulo cuando no se pudo pedir; entonces [problem] dice por qué y [errorCode] trae el
 * código del contrato si el equipo lo rechazó (`opciones_no_validas`, `alcance_no_valido`, …).
 */
data class RelaunchHostPlan(
    val machineID: String,
    val machineName: String,
    val plan: RelaunchPlan?,
    val problem: RelaunchHostProblem? = null,
    val errorCode: String? = null,
)
