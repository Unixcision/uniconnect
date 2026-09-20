package com.unixcision.uniconnect.android.data

import android.content.Context
import com.unixcision.uniconnect.android.domain.ConnectionDiary
import com.unixcision.uniconnect.android.domain.ConnectionEvent
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Guarda el diario de conexiones en un fichero de la app.
 *
 * Hace falta justamente porque el informe se pide cuando algo ha ido mal: si el diario se borrara
 * al cerrar la app —o al matarla Android por memoria, que es lo normal cuando la red se ha caído y
 * la pantalla lleva un rato apagada—, lo que se quería contar habría desaparecido antes de poder
 * contarlo.
 *
 * Ni lee ni escribe nada que no sea el propio diario, y una lectura rota se trata como diario
 * vacío: un fichero corrupto no puede impedir que la app arranque.
 */
class FileConnectionDiaryStore(context: Context) : ConnectionDiary.Store {
    private val file = File(context.filesDir, "diario-conexiones.json")

    override fun load(): List<ConnectionEvent> = runCatching {
        if (!file.exists()) return emptyList()
        val array = JSONArray(file.readText())
        (0 until array.length()).mapNotNull { index -> decode(array.optJSONObject(index)) }
    }.getOrDefault(emptyList())

    override fun save(events: List<ConnectionEvent>) {
        runCatching {
            val array = JSONArray()
            events.forEach { array.put(encode(it)) }
            file.writeText(array.toString())
        }
    }

    private fun encode(event: ConnectionEvent): JSONObject = JSONObject().apply {
        put("at", event.at)
        put("stage", event.stage)
        put("machine", event.machine)
        put("endpoint", event.endpoint)
        put("outcome", event.outcome.name)
        put("millis", event.millis)
        event.detail?.let { put("detail", it) }
        event.network?.let { put("network", it) }
    }

    private fun decode(json: JSONObject?): ConnectionEvent? {
        val source = json ?: return null
        // Un desenlace que esta versión no conoce no se inventa ni se descarta: el apunte sigue
        // siendo la prueba de que hubo un intento, y su detalle explica cómo acabó.
        val outcome = runCatching { ConnectionEvent.Outcome.valueOf(source.optString("outcome")) }
            .getOrDefault(ConnectionEvent.Outcome.ERROR_TRANSPORTE)
        return ConnectionEvent(
            at = source.optLong("at"),
            stage = source.optString("stage"),
            machine = source.optString("machine"),
            endpoint = source.optString("endpoint"),
            outcome = outcome,
            millis = source.optLong("millis"),
            detail = source.optString("detail").ifEmpty { null },
            network = source.optString("network").ifEmpty { null },
        )
    }
}
