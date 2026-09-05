package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.*
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import org.json.JSONArray
import org.json.JSONObject

/** Subscribe before listing so a concurrent notice is recovered by list or event, then deduplicated. */
class NativeNotificationClient(private val rpc: FramedRpcClient) : NotificationClient {
    override fun observe(machine: Machine): Flow<List<RemoteNotice>> = flow {
        rpc.open(machine.endpoint).use { session ->
            val streamID = UUID.randomUUID().toString()
            val subscribed = session.call("mobile.events.subscribe", JSONObject().put("stream_id", streamID).put("topics", JSONArray().put("notification.created")))
            require(subscribed.value.getJSONObject("result").getString("stream_id") == streamID)
            var cursor: String? = null
            val cursors = mutableSetOf<String>()
            var count = 0
            do {
                val params = JSONObject().put("limit", 200)
                cursor?.let { params.put("before", it) }
                val result = session.call("mobile.notifications.list", params).value.getJSONObject("result")
                val notices = result.getJSONArray("notifications")
                val batch = List(notices.length()) { decode(notices.getJSONObject(it)) }
                count += batch.size
                require(count <= 10_000)
                emit(batch)
                cursor = if (result.isNull("next_cursor")) null else result.getString("next_cursor")
                if (cursor != null) require(cursors.add(cursor))
            } while (cursor != null)
            while (true) {
                val event = session.nextEventOrHeartbeat(30_000)
                if (event == null) {
                    // The bounded read-only heartbeat also recovers a retained notification after an idle gap.
                    val result = session.call("mobile.notifications.list", JSONObject().put("limit", 200)).value.getJSONObject("result")
                    val notices = result.getJSONArray("notifications")
                    emit(List(notices.length()) { decode(notices.getJSONObject(it)) })
                } else if (event.value.optString("topic") == "notification.created") {
                    emit(listOf(decode(event.value.getJSONObject("payload"))))
                }
            }
        }
    }.catch { failure ->
        if (failure is org.json.JSONException || failure is IllegalArgumentException) throw MachineFailure.ProtocolMismatch()
        throw failure
    }.flowOn(Dispatchers.Default)

    private fun decode(value: JSONObject): RemoteNotice {
        val id = value.getString("id").also { UUID.fromString(it) }
        val workspaceID = value.getString("workspace_id").also { UUID.fromString(it) }
        val windowID = if (value.isNull("surface_id")) null else value.getString("surface_id").also { UUID.fromString(it) }
        return RemoteNotice(id, workspaceID, windowID, value.getLong("created_at_ms"), value.getBoolean("is_read"))
    }
}
