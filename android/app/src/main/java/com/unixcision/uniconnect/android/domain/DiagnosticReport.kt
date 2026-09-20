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

    /** El informe completo, listo para compartir. */
    fun render(
        environment: DiagnosticEnvironment,
        events: List<ConnectionEvent>,
        now: Long = System.currentTimeMillis(),
    ): String = buildString {
        appendLine("UniConnect · informe de conexión")
        appendLine("generado: ${stamp(now)} (${TimeZone.getDefault().id})")
        appendLine()
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
        appendLine()

        val failures = events.count { it.outcome != ConnectionEvent.Outcome.OK }
        appendLine("Intentos registrados: ${events.size} · fallidos: $failures")
        appendLine()

        if (events.isEmpty()) {
            appendLine("(todavía no hay intentos registrados)")
            return@buildString
        }

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

    /** Un resumen de una línea, para el propio modal y para el asunto del envío. */
    fun headline(events: List<ConnectionEvent>): String {
        val last = events.lastOrNull { it.outcome != ConnectionEvent.Outcome.OK }
            ?: return "Sin fallos registrados"
        return "${last.stage}: ${last.outcome.name.lowercase()}" +
            (last.detail?.let { " · $it" }.orEmpty())
    }

    /** Nombre de archivo estable y ordenable, para cuando se comparte como fichero. */
    fun fileName(now: Long = System.currentTimeMillis()): String {
        val format = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US)
        return "uniconnect-conexion-${format.format(Date(now))}.txt"
    }
}
