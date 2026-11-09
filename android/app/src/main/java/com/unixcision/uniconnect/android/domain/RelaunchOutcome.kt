package com.unixcision.uniconnect.android.domain

/**
 * Cómo acabó una petición entera, sumando sus equipos, para enseñarlo en un solo diálogo.
 *
 * Se cuenta por objetivo y no por equipo: «Relanzadas 25 de 26» dice más que «3 equipos bien». Lo
 * que falló en la llamada a un equipo va aparte, en [problems], con su nombre.
 */
data class RelaunchOutcome(val verb: RelaunchVerb, val hosts: List<RelaunchHostResult>) {
    val operations: List<RelaunchOperation> get() = hosts.mapNotNull { it.operation }

    val results: List<RelaunchResult> get() = operations.flatMap { it.results }

    val verified: Int get() = results.count { it.state == RelaunchTargetState.VERIFIED }

    val total: Int get() = results.size

    val needingUser: List<RelaunchResult> get() = operations.flatMap { it.needingUser }

    val retryable: List<RelaunchResult> get() = operations.flatMap { it.retryable }

    /** Los que se dejaron como estaban. Ver [RelaunchReasons.untouched]. */
    val untouched: List<RelaunchResult> get() = operations.flatMap { RelaunchReasons.untouched(it) }

    /** Los motivos distintos de lo que no salió verificado. */
    val reasons: List<RelaunchReason> get() = RelaunchReasons.distinctReasons(needingUser + untouched + retryable)

    /** `claude update` en cada instalación, de todos los equipos. */
    val updates: List<RelaunchUpdate> get() = operations.flatMap { it.updates }

    /** Monitores o shells de fondo guardados antes de cerrar. */
    val monitorsSaved: Int get() = results.sumOf { it.backgroundSaved ?: 0 }

    /** A cuántas IA se les escribió tras reabrir (lo que gastó cupo). */
    val messagesSent: Int get() = results.count { it.messageSent == true }

    /** Cuántos borradores volvieron a su compositor. */
    val draftsRestored: Int get() = results.count { it.draftRestored == true }

    /** Opciones de arranque que se quitaron por no conservarse, cada una una vez. */
    val droppedOptions: List<String> get() = results.flatMap { it.droppedOptions }.distinct()

    /** Modelo y effort que enseñan las barras de estado tras reabrir, cada combinación una vez. */
    val reportedModels: List<String> get() = results
        .mapNotNull { result -> listOfNotNull(result.model, result.effort).takeIf { it.isNotEmpty() }?.joinToString(" · ") }
        .distinct()

    /** Los equipos de los que no hay resultado, con su motivo. */
    val problems: List<RelaunchHostResult> get() = hosts.filter { it.problem != null }
}
