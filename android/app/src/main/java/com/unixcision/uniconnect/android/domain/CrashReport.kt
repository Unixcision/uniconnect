package com.unixcision.uniconnect.android.domain

import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * Un cierre inesperado de la app, guardado para poder contarlo después.
 *
 * Existe porque un fallo que mata la app se lleva consigo la única prueba de lo que pasó: la
 * persona ve «UniConnect sigue sin funcionar», pulsa cerrar, y no queda nada que enseñar. Aquí se
 * escribe **antes** de morir, y se lee en el arranque siguiente.
 *
 * No sale del móvil por su cuenta: se comparte cuando se decide compartirlo, por el mismo camino
 * que el informe de conexión.
 */
data class CrashReport(
    /** Cuándo se cerró, en milisegundos desde época. */
    val at: Long,
    /** En qué hilo. `main` significa que se lo llevó la interfaz. */
    val thread: String,
    /** Qué versión estaba instalada. Diagnosticar sobre otra compilación es diagnosticar el aire. */
    val appVersion: String,
    /** La excepción y su causa, en una línea, para reconocerlo de un vistazo. */
    val summary: String,
    /** La traza entera, tal cual. */
    val stack: String,
) {
    /** El texto que se lee y se comparte. */
    fun render(): String = buildString {
        appendLine("── cierre inesperado ──")
        appendLine("cuando: ${stamp(at)}")
        appendLine("hilo:   $thread")
        appendLine("app:    $appVersion")
        appendLine("qué:    $summary")
        appendLine()
        appendLine(stack)
    }

    companion object {
        /**
         * Convierte una excepción en algo guardable.
         *
         * El resumen se queda con la causa raíz, no con la envoltura: `SecurityException` dentro de
         * un `RemoteException` se reconoce por la de dentro, que es la que dice qué falta.
         */
        fun of(thread: String, appVersion: String, failure: Throwable, at: Long = System.currentTimeMillis()): CrashReport {
            // Con tope de saltos: una cadena de causas puede formar un ciclo (A causada por B,
            // B causada por A). Java solo prohíbe que algo se cause a sí mismo directamente, así
            // que un bucle ingenuo se quedaría dando vueltas **mientras el proceso se muere** y no
            // se guardaría nada. Doce saltos cubren cualquier envoltura real.
            var root: Throwable = failure
            repeat(12) {
                val cause = root.cause ?: return@repeat
                if (cause === root) return@repeat
                root = cause
            }
            val summary = root::class.java.name +
                (root.message?.takeIf { it.isNotBlank() }?.let { ": $it" }.orEmpty())
            return CrashReport(
                at = at, thread = thread, appVersion = appVersion,
                summary = summary.take(400),
                stack = failure.stackTraceToString().take(24_000),
            )
        }

        private fun stamp(at: Long): String {
            val format = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US)
            format.timeZone = TimeZone.getDefault()
            return format.format(Date(at))
        }
    }
}
