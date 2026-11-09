package com.unixcision.uniconnect.android.domain

/**
 * Cómo acabó un equipo: su operación, o por qué no hay nada que contar de él.
 *
 * [operation] es nula cuando no hubo plan que ejecutar o se perdió la respuesta; [problem] lo dice.
 */
data class RelaunchHostResult(
    val machineID: String,
    val machineName: String,
    val operation: RelaunchOperation?,
    val problem: RelaunchHostProblem? = null,
    val errorCode: String? = null,
)
