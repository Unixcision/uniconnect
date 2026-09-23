package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.InboxClient
import com.unixcision.uniconnect.android.domain.InboxDeletion
import com.unixcision.uniconnect.android.domain.InboxDeletionResult
import com.unixcision.uniconnect.android.domain.InboxEntry
import com.unixcision.uniconnect.android.domain.InboxKind
import com.unixcision.uniconnect.android.domain.InboxListing
import com.unixcision.uniconnect.android.domain.Machine
import com.unixcision.uniconnect.android.domain.MachineFailure
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.Base64

/**
 * `inbox.v1` por la misma conexión privada que el resto: una sesión por operación, y en la
 * descarga una sola sesión para todos sus trozos (1 MiB crudo, 1,4 MiB en base64, muy por debajo
 * del límite de trama).
 */
class NativeInboxClient(private val rpc: FramedRpcClient) : InboxClient {
    override suspend fun list(machine: Machine, limit: Int, offset: Int): InboxListing =
        rpc.open(machine.endpoint).use { RpcInboxSession(it).list(limit, offset) }

    override suspend fun delete(machine: Machine, deletion: InboxDeletion): InboxDeletionResult =
        rpc.open(machine.endpoint).use { RpcInboxSession(it).delete(deletion) }

    override suspend fun download(machine: Machine, entry: InboxEntry, destination: File, progress: (Long) -> Unit) =
        rpc.open(machine.endpoint).use { RpcInboxSession(it).download(entry, destination, progress) }

    /** Las tres RPC sobre una sesión abierta; probadas contra un equipo simulado en un socket. */
    internal class RpcInboxSession(private val session: FramedRpcSession) {
        suspend fun list(limit: Int, offset: Int): InboxListing =
            parseListing(call("mobile.inbox.list", JSONObject().put("limit", limit).put("offset", offset)))

        suspend fun delete(deletion: InboxDeletion): InboxDeletionResult {
            val params = JSONObject().put("dry_run", deletion.dryRun)
            if (deletion.everything) params.put("all", true)
            deletion.olderThanDays?.let { params.put("older_than_days", it) }
            deletion.largerThanBytes?.let { params.put("larger_than_bytes", it) }
            deletion.paths?.let { params.put("paths", JSONArray(it)) }
            val r = call("mobile.inbox.delete", params)
            return InboxDeletionResult(r.optBoolean("dry_run"), r.optInt("deleted"), r.optLong("freed_bytes"),
                r.optInt("remaining_count"), r.optLong("remaining_bytes"))
        }

        /**
         * Trae el archivo a un `.part` junto a [destination] y solo al acabar lo renombra: una vista
         * previa nunca ve un archivo a medias, y una descarga cortada no deja basura con buen nombre.
         */
        suspend fun download(entry: InboxEntry, destination: File, progress: (Long) -> Unit) {
            val part = File(destination.parentFile, destination.name + ".part")
            destination.parentFile?.mkdirs()
            try {
                part.outputStream().use { out ->
                    var offset = 0L
                    while (true) {
                        val r = call("mobile.inbox.read", JSONObject().put("path", entry.path).put("offset", offset).put("length", CHUNK_BYTES), READ_DEADLINE_MILLIS)
                        val data = Base64.getDecoder().decode(r.optString("data"))
                        out.write(data)
                        offset += data.size
                        progress(offset)
                        if (r.optBoolean("eof") || offset >= r.optLong("size")) break
                        // Un trozo vacío antes del final es un equipo que no avanza: se corta aquí.
                        if (data.isEmpty()) throw MachineFailure.ProtocolMismatch()
                    }
                }
                if (!part.renameTo(destination)) throw java.io.IOException("No se pudo guardar la vista previa")
            } finally {
                part.delete()
            }
        }

        private suspend fun call(method: String, params: JSONObject, deadlineMillis: Long = 15_000): JSONObject =
            session.call(method, params, deadlineMillis).value.getJSONObject("result")
    }

    internal companion object {
        const val CHUNK_BYTES = 1_048_576

        /** Un trozo de 1 MiB a 20 KB/s por datos móviles tarda casi un minuto. */
        const val READ_DEADLINE_MILLIS = 60_000L

        /** La respuesta de `inbox.list` tal como la da el Mac o Linux. Puro: se prueba en la JVM. */
        fun parseListing(r: JSONObject): InboxListing {
            val entries = r.optJSONArray("entries") ?: JSONArray()
            return InboxListing(
                count = r.optInt("count"),
                totalBytes = r.optLong("total_bytes"),
                oldest = if (r.isNull("oldest")) null else r.optLong("oldest"),
                newest = if (r.isNull("newest")) null else r.optLong("newest"),
                entries = (0 until entries.length()).mapNotNull { i ->
                    val e = entries.optJSONObject(i) ?: return@mapNotNull null
                    val path = e.optString("path").ifEmpty { return@mapNotNull null }
                    InboxEntry(path, e.optString("absolute"), e.optString("name").ifEmpty { path.substringAfterLast('/') },
                        e.optLong("size"), e.optLong("modified"), InboxKind.fromWire(e.optString("kind")))
                },
            )
        }
    }
}
