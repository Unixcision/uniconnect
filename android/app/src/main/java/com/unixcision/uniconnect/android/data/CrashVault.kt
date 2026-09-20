package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.CrashReport
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Guarda los cierres inesperados en disco antes de que la app muera, y los devuelve al arrancar.
 *
 * Es el sustituto local de un Crashlytics: **nada sale del móvil por su cuenta**. Se escribe aquí,
 * se lee en el arranque siguiente y se comparte solo si se decide compartirlo. Un informe de fallos
 * que viaja sin permiso a un servidor ajeno es exactamente lo que no se quería.
 *
 * El apunte se escribe de forma síncrona desde el manejador de excepciones no capturadas: el
 * proceso está a punto de morir, así que no hay a quién delegarlo. Es un fichero pequeño y una
 * sola escritura.
 */
class CrashVault(
    private val file: File,
    /** Qué versión está instalada, para que el apunte no se diagnostique sobre otra compilación. */
    private val appVersion: () -> String,
    /** Cuántos cierres se conservan. Los viejos dejan de explicar nada. */
    private val capacity: Int = 5,
) {
    /**
     * Engancha el manejador global, **encadenando** el que ya hubiera.
     *
     * Encadenar no es cortesía: el de Android es el que enseña el diálogo y mata el proceso. Si se
     * sustituyera sin llamarlo, la app se quedaría colgada con la pantalla congelada en vez de
     * cerrarse, que es peor que el propio fallo.
     */
    fun install() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, failure ->
            runCatching { record(CrashReport.of(thread.name, appVersion(), failure)) }
            previous?.uncaughtException(thread, failure)
        }
    }

    /** Lo guardado, del más reciente al más antiguo. Una lectura rota devuelve lista vacía. */
    fun pending(): List<CrashReport> = runCatching {
        if (!file.exists()) return emptyList()
        val array = JSONArray(file.readText())
        (0 until array.length()).mapNotNull { decode(array.optJSONObject(it)) }.sortedByDescending { it.at }
    }.getOrDefault(emptyList())

    fun clear() { runCatching { file.delete() } }

    @Synchronized
    private fun record(report: CrashReport) {
        val kept = (listOf(report) + pending()).take(capacity)
        val array = JSONArray()
        kept.forEach { array.put(encode(it)) }
        file.writeText(array.toString())
    }

    private fun encode(report: CrashReport): JSONObject = JSONObject().apply {
        put("at", report.at)
        put("thread", report.thread)
        put("appVersion", report.appVersion)
        put("summary", report.summary)
        put("stack", report.stack)
    }

    private fun decode(json: JSONObject?): CrashReport? {
        val source = json ?: return null
        val stack = source.optString("stack")
        if (stack.isEmpty()) return null
        return CrashReport(
            at = source.optLong("at"),
            thread = source.optString("thread").ifEmpty { "?" },
            appVersion = source.optString("appVersion").ifEmpty { "?" },
            summary = source.optString("summary").ifEmpty { "sin resumen" },
            stack = stack,
        )
    }
}
