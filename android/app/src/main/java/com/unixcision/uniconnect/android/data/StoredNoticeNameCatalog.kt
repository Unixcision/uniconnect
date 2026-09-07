package com.unixcision.uniconnect.android.data

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import com.unixcision.uniconnect.android.domain.MachineSnapshot
import com.unixcision.uniconnect.android.domain.NoticeNameCatalog
import com.unixcision.uniconnect.android.domain.NoticeNames
import com.unixcision.uniconnect.android.domain.RemoteNotice
import com.unixcision.uniconnect.android.domain.RemoteWindow
import com.unixcision.uniconnect.android.domain.RemoteWorkspace
import kotlinx.coroutines.flow.first
import org.json.JSONArray
import org.json.JSONObject

/** Keeps only ids and names: no terminal content, no agent targets, nothing a notice cannot show. */
class StoredNoticeNameCatalog(private val store: DataStore<Preferences>) : NoticeNameCatalog {
    private fun key(machineID: String) = stringPreferencesKey("notice_names.v1.$machineID")

    override suspend fun remember(machineID: String, snapshot: MachineSnapshot) {
        val encoded = JSONArray().apply {
            snapshot.workspaces.forEach { workspace ->
                put(JSONObject().put("id", workspace.id).put("name", workspace.name).put("windows", JSONArray().apply {
                    workspace.windows.forEach { put(JSONObject().put("id", it.id).put("name", it.name)) }
                }))
            }
        }.toString()
        store.edit { it[key(machineID)] = encoded }
    }

    override suspend fun lookup(machineID: String, notice: RemoteNotice): NoticeNames {
        val raw = store.data.first()[key(machineID)] ?: return NoticeNames.NONE
        val workspaces = runCatching { decode(raw) }.getOrDefault(emptyList())
        return NoticeNames.resolve(workspaces, notice)
    }

    private fun decode(raw: String): List<RemoteWorkspace> {
        val array = JSONArray(raw)
        return List(array.length()) { index ->
            val item = array.getJSONObject(index)
            val windows = item.getJSONArray("windows")
            RemoteWorkspace(
                id = item.getString("id"), name = item.getString("name"), isSSH = null,
                windows = List(windows.length()) { w -> windows.getJSONObject(w).let { RemoteWindow(it.getString("id"), it.getString("name"), "") } },
            )
        }
    }
}
