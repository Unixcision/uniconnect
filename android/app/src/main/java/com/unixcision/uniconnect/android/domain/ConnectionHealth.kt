package com.unixcision.uniconnect.android.domain

/**
 * Cómo están las conexiones **ahora**, sacado del diario, sin confundir lo pasado con lo presente.
 *
 * El informe de conexión enseñaba arriba el último fallo que hubiera habido, aunque llevara horas
 * resuelto: con las dos máquinas conectadas decía «error_transporte · SocketTimeoutException», y
 * eso es un dato falso cuando no hay problema. Aquí cada máquina se juzga por su **último**
 * intento: si salió bien, responde; si los últimos salieron mal, está caída desde el primero de
 * esa racha. Los fallos ya superados quedan como incidentes resueltos, con su hora de vuelta.
 *
 * Un intento cancelado (la persona cambió de pantalla) no es ni éxito ni fallo y no cuenta. Una
 * máquina que la app tiene conectada en este momento nunca está caída, diga lo que diga el diario.
 */
data class ConnectionHealth(val machines: List<MachineHealth>, val incidents: List<ConnectionIncident>) {
    /** Las máquinas que no responden ahora mismo. */
    val down: List<MachineHealth> get() = machines.filter { it.down }

    /** Nada caído ahora (puede haber incidentes pasados, ya resueltos). */
    val healthy: Boolean get() = down.isEmpty()

    /** El último incidente que se resolvió, para contarlo como historia y no como problema. */
    val lastResolved: ConnectionIncident? get() = incidents.filter { it.resolvedAt != null }.maxByOrNull { it.resolvedAt!! }

    companion object {
        /**
         * Stages that ask a machine to do something rather than to connect. The host answering
         * «no» to a creation still answered, so they never make a machine look down; the report
         * lists their failures apart.
         */
        val actionStages: Set<String> = setOf("crear", "cerrar")

        /**
         * El estado de cada máquina del diario.
         *
         * - Parameter events: el diario, en cualquier orden.
         * - Parameter connectedNow: nombres de las máquinas que la app tiene conectadas ahora;
         *   nulo cuando no se sabe.
         */
        fun of(events: List<ConnectionEvent>, connectedNow: Set<String>? = null): ConnectionHealth {
            val counted = events.filter { it.outcome != ConnectionEvent.Outcome.CANCELADO && it.stage !in actionStages }.sortedBy { it.at }
            val incidents = mutableListOf<ConnectionIncident>()
            val machines = counted.groupBy { it.machine }.map { (machine, attempts) ->
                var run = mutableListOf<ConnectionEvent>()
                for (attempt in attempts) {
                    if (attempt.outcome == ConnectionEvent.Outcome.OK) {
                        if (run.isNotEmpty()) incidents += ConnectionIncident(machine, run.toList(), resolvedAt = attempt.at)
                        run = mutableListOf()
                    } else run += attempt
                }
                val stillFailing = run.isNotEmpty() && connectedNow?.contains(machine) != true
                if (run.isNotEmpty()) incidents += ConnectionIncident(machine, run.toList(), resolvedAt = null)
                MachineHealth(
                    machine = machine,
                    down = stillFailing,
                    lastAttempt = attempts.last(),
                    lastOk = attempts.lastOrNull { it.outcome == ConnectionEvent.Outcome.OK },
                    failing = if (stillFailing) run.toList() else emptyList(),
                )
            }
            return ConnectionHealth(machines.sortedBy { it.machine }, incidents.sortedBy { it.from })
        }
    }
}

/** Una máquina del diario y cómo está ahora. */
data class MachineHealth(
    val machine: String,
    /** No responde ahora: sus últimos intentos fallaron y la app no la tiene conectada. */
    val down: Boolean,
    val lastAttempt: ConnectionEvent,
    val lastOk: ConnectionEvent?,
    /** La racha de fallos en curso, de la más antigua a la última; vacía si responde. */
    val failing: List<ConnectionEvent>,
) {
    /** Desde cuándo falla, si está caída. */
    val downSince: Long? get() = failing.firstOrNull()?.at
}

/** Una racha de fallos seguidos de una máquina, resuelta o en curso. */
data class ConnectionIncident(
    val machine: String,
    val attempts: List<ConnectionEvent>,
    /** Cuándo volvió a responder; nulo si sigue fallando (o el diario acaba en la racha). */
    val resolvedAt: Long?,
) {
    val from: Long get() = attempts.first().at
    val last: ConnectionEvent get() = attempts.last()
}
