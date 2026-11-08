package com.unixcision.uniconnect.android.domain

import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/** El entorno en el que ocurrió el fallo, tal y como se pueda leer del sistema. */
data class DiagnosticEnvironment(
    val appVersion: String,
    val appBuild: String,
    val androidRelease: String,
    val sdkInt: Int,
    val deviceModel: String,
    val network: String,
    val networkOperator: String? = null,
    val tailscaleAddress: String? = null,
    val batterySaver: Boolean? = null,
    val backgroundRestricted: Boolean? = null,
)

/**
 * Convierte lo ocurrido en algo que una persona pueda leer, pegar o mandar.
 *
 * El formato es texto llano a propósito. Un informe que solo se puede subir es un informe que se
 * pierde cuando justamente no hay conexión —que es el caso que este informe existe para explicar—,
 * así que tiene que poder compartirse por cualquier vía: un mensaje, un correo, un pantallazo.
 *
 * Lleva lo que un diagnóstico necesita para no tener que preguntar nada: versión y compilación,
 * modelo y versión de Android, qué red había, y el historial de intentos con **su hora, su duración
 * y su desenlace exacto**. Un fallo que tarda 20 s y uno que tarda 30 ms no tienen la misma causa,
 * y sin la duración no se distinguen.
 */
object DiagnosticReport {
    private fun stamp(at: Long): String {
        val format = SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US)
        format.timeZone = TimeZone.getDefault()
        return format.format(Date(at))
    }

    /**
     * El informe completo, listo para compartir.
     *
     * `environment` admite nulo a propósito: si el sistema no dejó leer nada, el informe sale igual
     * con lo que sí se sabe. Un informe incompleto sirve; uno que no se puede abrir, no.
     */
    fun render(
        environment: DiagnosticEnvironment?,
        events: List<ConnectionEvent>,
        now: Long = System.currentTimeMillis(),
        crashes: List<CrashReport> = emptyList(),
        /** Máquinas que la app tiene conectadas ahora: nunca salen como caídas. Nulo si no se sabe. */
        connectedNow: Set<String>? = null,
    ): String = buildString {
        appendLine("UniConnect · informe de conexión")
        appendLine("generado: ${stamp(now)} (${TimeZone.getDefault().id})")
        appendLine()
        if (environment == null) appendLine("(no se pudo leer el entorno del móvil)")
        else {
            appendLine("App        ${environment.appVersion} (${environment.appBuild})")
            appendLine("Dispositivo ${environment.deviceModel} · Android ${environment.androidRelease} (API ${environment.sdkInt})")
            appendLine("Red        ${environment.network}${environment.networkOperator?.let { " · $it" }.orEmpty()}")
            environment.tailscaleAddress?.let { appendLine("Tailscale  $it") }
            environment.batterySaver?.let { appendLine("Ahorro de batería: ${if (it) "activado" else "desactivado"}") }
            environment.backgroundRestricted?.let {
                // Importa: con esto activado Android corta la app en segundo plano y las conexiones
                // mueren sin que la app tenga nada que ver.
                appendLine("Uso en segundo plano restringido: ${if (it) "SÍ" else "no"}")
            }
        }
        appendLine()

        // Los cierres van arriba del todo: si la app se ha muerto, eso explica el resto del
        // informe mucho antes que cualquier intento de conexión.
        if (crashes.isNotEmpty()) {
            appendLine("CIERRES INESPERADOS: ${crashes.size}")
            crashes.forEach { appendLine(it.render()) }
            appendLine()
        }

        if (events.isEmpty()) {
            appendLine("(todavía no hay intentos registrados)")
            return@buildString
        }

        // Primero lo que pasa AHORA, máquina a máquina: un fallo ya resuelto no es un problema
        // presente y no puede leerse como tal.
        val health = ConnectionHealth.of(events, connectedNow)
        appendLine(if (health.healthy) "ESTADO AHORA: todo bien" else "ESTADO AHORA: ${health.down.size} sin responder")
        for (machine in health.machines) {
            if (machine.down) {
                val last = machine.failing.last()
                appendLine("  ${machine.machine}: NO RESPONDE desde ${clock(machine.downSince!!)} · ${machine.failing.size} fallos seguidos · ${describe(last)}")
            } else {
                appendLine("  ${machine.machine}: responde · último intento ${machine.lastAttempt.stage} ${clock(machine.lastAttempt.at)}")
            }
        }
        appendLine()

        if (health.incidents.isNotEmpty()) {
            appendLine("INCIDENTES (rachas de fallos, de la más reciente a la más antigua)")
            for (incident in health.incidents.sortedByDescending { it.from }) {
                val end = incident.resolvedAt?.let { "resuelto a las ${clock(it)}" } ?: "SIN RESOLVER"
                appendLine("  ${clock(incident.from)} ${incident.machine} · ${incident.attempts.size} fallo(s) · ${describe(incident.last)} · $end")
            }
            appendLine()
        }

        // Creating or closing something is not connecting: a «no» from the host is listed here,
        // with its exact answer, and never makes the machine look down.
        val failedActions = events.filter { it.stage in ConnectionHealth.actionStages && it.outcome != ConnectionEvent.Outcome.OK && it.outcome != ConnectionEvent.Outcome.CANCELADO }
        if (failedActions.isNotEmpty()) {
            appendLine("ACCIONES QUE FALLARON (las últimas)")
            for (action in failedActions.takeLast(10).asReversed()) {
                appendLine("  ${clock(action.at)} ${action.machine} · ${describe(action)} · ${action.millis} ms")
            }
            appendLine()
        }

        val failures = events.count { it.outcome != ConnectionEvent.Outcome.OK }
        appendLine("REGISTRO · últimos ${events.size} intentos · fallidos: $failures")
        appendLine()

        appendLine("hora                     fase        desenlace         ms   equipo / detalle")
        appendLine("-".repeat(96))
        for (event in events) {
            append(stamp(event.at).padEnd(24))
            append(event.stage.padEnd(12).take(12))
            append(event.outcome.name.lowercase().padEnd(18).take(18))
            append(event.millis.toString().padStart(6))
            append("   ${event.machine} → ${event.endpoint}")
            event.network?.let { append(" [$it]") }
            event.detail?.let { append("\n".padEnd(1) + "    ↳ $it") }
            appendLine()
        }
    }

    /**
     * Un resumen de una línea, para el propio modal y para el asunto del envío.
     *
     * Dice cómo están las cosas **ahora**: una máquina caída, con desde cuándo y por qué; o que
     * todo responde, contando el último fallo como resuelto. Nunca presenta un fallo pasado como
     * si estuviera ocurriendo.
     */
    fun headline(events: List<ConnectionEvent>, crashes: List<CrashReport> = emptyList(), connectedNow: Set<String>? = null): String {
        // Un cierre manda sobre cualquier fallo de conexión: es lo más grave que hay que contar.
        crashes.firstOrNull()?.let { return "la app se cerró sola · ${it.summary.substringAfterLast('.')}" }
        if (events.isEmpty()) return "Todavía no hay intentos registrados"
        val health = ConnectionHealth.of(events, connectedNow)
        health.down.firstOrNull()?.let { machine ->
            val more = health.down.size - 1
            return "${machine.machine} no responde desde las ${clock(machine.downSince!!)}: ${machine.failing.size} fallos seguidos · " +
                describe(machine.failing.last()) + if (more > 0) " (y $more máquina${if (more == 1) "" else "s"} más)" else ""
        }
        val resolved = health.lastResolved ?: return "Todo bien ahora · sin fallos registrados"
        return "Todo bien ahora · el último fallo (${resolved.machine}, ${describe(resolved.last)}) se resolvió a las ${clock(resolved.resolvedAt!!)}"
    }

    /** Si hay algo que arreglar ahora: un cierre de la app o una máquina que no responde. */
    fun isProblem(events: List<ConnectionEvent>, crashes: List<CrashReport> = emptyList(), connectedNow: Set<String>? = null): Boolean =
        crashes.isNotEmpty() || !ConnectionHealth.of(events, connectedNow).healthy

    private fun describe(event: ConnectionEvent): String =
        "${event.stage}: ${event.outcome.name.lowercase()}" + (event.detail?.let { " · $it" }.orEmpty())

    private fun clock(at: Long): String {
        val format = SimpleDateFormat("HH:mm:ss", Locale.US)
        format.timeZone = TimeZone.getDefault()
        return format.format(Date(at))
    }

    /** Nombre de archivo estable y ordenable, para cuando se comparte como fichero. */
    fun fileName(now: Long = System.currentTimeMillis()): String {
        val format = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US)
        return "uniconnect-conexion-${format.format(Date(now))}.txt"
    }
}
