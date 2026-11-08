package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.SentMessage
import com.unixcision.uniconnect.android.domain.SentMessageHistory
import java.io.File
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject

/**
 * The sent messages in the app's private files: one index, `enviados.json`, rewritten whole and
 * atomically on every change; it holds short texts and at most [maxMessages] of them.
 *
 * A message still being sent when the app died comes back as
 * [SentMessage.State.UNCONFIRMED]: it may have arrived, and the reader decides.
 */
class FileSentMessageHistory(
    private val directory: File,
    private val clock: () -> Long = System::currentTimeMillis,
    private val maxMessages: Int = SentMessageHistory.MAX_MESSAGES,
) : SentMessageHistory {
    private val index = File(directory, "enviados.json")
    private val lock = Any()
    private val mutable = MutableStateFlow(load())
    override val messages: StateFlow<List<SentMessage>> = mutable.asStateFlow()

    init {
        // Kept under an older, larger limit: trimmed as soon as it is opened.
        synchronized(lock) { if (mutable.value.size > maxMessages) change { it.take(maxMessages) } }
    }

    override fun record(text: String, withEnter: Boolean, machineName: String?, windowName: String?): String {
        val message = SentMessage(
            id = UUID.randomUUID().toString(), createdAt = clock(), text = text, withEnter = withEnter,
            state = SentMessage.State.SENDING, machineName = machineName, windowName = windowName,
        )
        synchronized(lock) { change { (listOf(message) + it).take(maxMessages) } }
        return message.id
    }

    override fun settle(id: String, delivered: Boolean) = synchronized(lock) {
        val state = if (delivered) SentMessage.State.DELIVERED else SentMessage.State.FAILED
        change { list -> list.map { if (it.id == id) it.copy(state = state) else it } }
    }

    override fun delete(ids: Set<String>) = synchronized(lock) { change { list -> list.filterNot { it.id in ids } } }

    override fun clear() = synchronized(lock) { change { emptyList() } }

    private fun change(update: (List<SentMessage>) -> List<SentMessage>) {
        val next = update(mutable.value)
        mutable.value = next
        save(next)
    }

    private fun save(messages: List<SentMessage>) {
        runCatching {
            directory.mkdirs()
            val array = JSONArray()
            messages.forEach { message ->
                array.put(
                    JSONObject()
                        .put("id", message.id).put("created_at", message.createdAt).put("text", message.text)
                        .put("with_enter", message.withEnter).put("state", message.state.name)
                        .putOpt("machine", message.machineName).putOpt("window", message.windowName),
                )
            }
            val temporary = File(directory, "enviados.json.tmp")
            temporary.writeText(JSONObject().put("version", 1).put("messages", array).toString())
            if (!temporary.renameTo(index)) temporary.delete()
        }
    }

    private fun load(): List<SentMessage> = runCatching {
        val array = JSONObject(index.readText()).getJSONArray("messages")
        (0 until array.length()).map { position ->
            val item = array.getJSONObject(position)
            val state = runCatching { SentMessage.State.valueOf(item.getString("state")) }.getOrDefault(SentMessage.State.UNCONFIRMED)
            SentMessage(
                id = item.getString("id"), createdAt = item.getLong("created_at"), text = item.getString("text"),
                withEnter = item.optBoolean("with_enter"),
                state = if (state == SentMessage.State.SENDING) SentMessage.State.UNCONFIRMED else state,
                machineName = item.optString("machine").ifEmpty { null },
                windowName = item.optString("window").ifEmpty { null },
            )
        }
    }.getOrDefault(emptyList())
}
