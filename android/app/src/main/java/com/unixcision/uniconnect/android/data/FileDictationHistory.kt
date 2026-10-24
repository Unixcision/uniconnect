package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.AudioClip
import com.unixcision.uniconnect.android.domain.DictationHistory
import com.unixcision.uniconnect.android.domain.DictationRecord
import com.unixcision.uniconnect.android.domain.DictationRetention
import com.unixcision.uniconnect.android.domain.DictationTarget
import java.io.File
import java.util.IdentityHashMap
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject

/**
 * The dictation history in the app's private files: one `<id>.m4a` per recording and an index,
 * `indice.json`, written whole on every change (it holds a few hundred short entries at most).
 *
 * Calls arrive from the dictation engines' worker threads and from the screen; one lock keeps the
 * list, the files and the index consistent. An entry that was still being transcribed when the
 * app died comes back as [DictationRecord.State.UNREAD], with its audio.
 */
class FileDictationHistory(
    private val directory: File,
    private val clock: () -> Long = System::currentTimeMillis,
    private val maxRecords: Int = DictationRetention.MAX_RECORDS,
    private val maxAudioBytes: Long = DictationRetention.MAX_AUDIO_BYTES,
) : DictationHistory {
    private val index = File(directory, "indice.json")
    private val lock = Any()
    /** The entry of each clip still in an engine's hands; identity, because clips carry no id. */
    private val entries = IdentityHashMap<AudioClip, String>()
    private val mutable = MutableStateFlow(load())
    override val records: StateFlow<List<DictationRecord>> = mutable.asStateFlow()

    override fun keep(clip: AudioClip, target: DictationTarget?) {
        synchronized(lock) { if (entries.containsKey(clip)) return }
        val id = UUID.randomUUID().toString()
        val audio = File(directory, "$id.m4a")
        val written = runCatching {
            directory.mkdirs()
            val bytes = clip.read()
            audio.writeBytes(bytes)
            bytes.size.toLong()
        }.getOrNull()
        val record = DictationRecord(
            id = id, createdAt = clock(), text = null, state = DictationRecord.State.TRANSCRIBING,
            audioPath = if (written != null) audio.path else null, audioBytes = written ?: 0L,
            machineName = target?.machine?.name, machineId = target?.machine?.id,
        )
        synchronized(lock) {
            entries[clip] = id
            change { listOf(record) + it }
        }
    }

    override fun transcribed(clip: AudioClip, text: String) = finish(clip) { it.copy(text = text, state = DictationRecord.State.DONE) }

    override fun unread(clip: AudioClip) = finish(clip) { it.copy(state = DictationRecord.State.UNREAD) }

    override fun replaceText(id: String, text: String) = synchronized(lock) {
        change { list -> list.map { if (it.id == id) it.copy(text = text, state = DictationRecord.State.DONE) else it } }
    }

    override fun delete(ids: Set<String>) = synchronized(lock) {
        change { list ->
            list.filter { it.id in ids }.forEach { record -> record.audioPath?.let { File(it).delete() } }
            list.filterNot { it.id in ids }
        }
    }

    override fun deleteAudio(ids: Set<String>) = synchronized(lock) {
        change { list -> list.map { if (it.id in ids) withoutAudio(it) else it } }
    }

    private fun finish(clip: AudioClip, update: (DictationRecord) -> DictationRecord) = synchronized(lock) {
        val id = entries.remove(clip) ?: return@synchronized
        change { list -> list.map { if (it.id == id) update(it) else it } }
    }

    private fun withoutAudio(record: DictationRecord): DictationRecord {
        record.audioPath?.let { File(it).delete() }
        return record.copy(audioPath = null)
    }

    /** Applies [update], trims to the limits and writes the index. Callers hold [lock]. */
    private fun change(update: (List<DictationRecord>) -> List<DictationRecord>) {
        var next = update(mutable.value)
        val trim = DictationRetention.trim(next, maxRecords, maxAudioBytes)
        if (!trim.isEmpty) {
            next.filter { it.id in trim.dropRecords }.forEach { record -> record.audioPath?.let { File(it).delete() } }
            next = next.filterNot { it.id in trim.dropRecords }.map { if (it.id in trim.dropAudio) withoutAudio(it) else it }
        }
        mutable.value = next
        save(next)
    }

    private fun save(list: List<DictationRecord>) {
        runCatching {
            directory.mkdirs()
            val array = JSONArray()
            list.forEach { record ->
                array.put(JSONObject()
                    .put("id", record.id).put("created_at", record.createdAt)
                    .put("text", record.text ?: JSONObject.NULL).put("state", record.state.name)
                    .put("audio", record.audioPath ?: JSONObject.NULL).put("audio_bytes", record.audioBytes)
                    .put("machine", record.machineName ?: JSONObject.NULL)
                    .put("machine_id", record.machineId ?: JSONObject.NULL))
            }
            val temporary = File(directory, "indice.json.tmp")
            temporary.writeText(array.toString())
            if (!temporary.renameTo(index)) { index.delete(); temporary.renameTo(index) }
        }
    }

    private fun load(): List<DictationRecord> {
        val array = runCatching { JSONArray(index.readText()) }.getOrNull() ?: return emptyList()
        return (0 until array.length()).mapNotNull { position ->
            runCatching {
                val item = array.getJSONObject(position)
                val audio = item.optString("audio").takeIf { !item.isNull("audio") && it.isNotEmpty() && File(it).exists() }
                val state = DictationRecord.State.valueOf(item.getString("state"))
                DictationRecord(
                    id = item.getString("id"), createdAt = item.getLong("created_at"),
                    text = if (item.isNull("text")) null else item.getString("text"),
                    // Nothing is transcribing at start-up: an entry left halfway was interrupted.
                    state = if (state == DictationRecord.State.TRANSCRIBING) DictationRecord.State.UNREAD else state,
                    audioPath = audio, audioBytes = if (audio != null) item.optLong("audio_bytes") else 0L,
                    machineName = if (item.isNull("machine")) null else item.getString("machine"),
                    machineId = if (!item.has("machine_id") || item.isNull("machine_id")) null else item.getString("machine_id"),
                )
            }.getOrNull()
        }
    }
}
