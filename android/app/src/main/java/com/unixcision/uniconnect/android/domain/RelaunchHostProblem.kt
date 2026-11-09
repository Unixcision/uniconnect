package com.unixcision.uniconnect.android.domain

/**
 * Por qué un equipo no tiene plan o resultado que enseñar.
 *
 * Es un fallo de la llamada a ese equipo, no una causa por objetivo: en «todo», los demás equipos
 * siguen adelante y este se nombra aparte.
 */
enum class RelaunchHostProblem {
    /** No se pudo pedir el plan: no contestó, o rechazó la petición (ver el código de error). */
    PLAN_FAILED,

    /** Se aceptó, pero se perdió la respuesta y no se ha podido saber cómo quedó. No se repite nada. */
    RESULT_UNKNOWN,
}
