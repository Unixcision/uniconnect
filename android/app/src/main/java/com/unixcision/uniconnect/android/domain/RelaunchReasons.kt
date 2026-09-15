package com.unixcision.uniconnect.android.domain

/**
 * Qué decirle a alguien sobre los objetivos de un relanzado que no salieron verificados.
 *
 * Existe por un caso real del 15-09-2026: el equipo cerró una IA viva y después informó de que se
 * había «quedado como estaba». La misma clase de silencio llegaba al móvil por otro camino — una
 * operación entera omitida enseñaba «Relanzadas 0 de N» y nada más, porque el diálogo solo miraba
 * verificados, pendientes y fallidos.
 */
object RelaunchReasons {
    /**
     * Los objetivos que se dejaron como estaban, sin tocarlos.
     *
     * Distinto de [RelaunchOperation.retryable]: en un fallo puede haber pasado algo, y en una
     * omisión no. Juntarlos es lo que hace que un recuento mienta.
     */
    fun untouched(operation: RelaunchOperation): List<RelaunchResult> =
        operation.results.filter { it.state == RelaunchTargetState.SKIPPED }

    /**
     * Los motivos distintos de una lista de resultados, cada uno una vez y en orden estable.
     *
     * Un recuento sin motivo obliga a mirar ventana por ventana; el mismo motivo repetido veinte
     * veces es igual de inútil. Un resultado sin causa no inventa ninguna.
     */
    fun distinctCauses(results: List<RelaunchResult>): List<RelaunchCause> =
        results.mapNotNull { it.cause }.distinct()
}
