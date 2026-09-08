package com.unixcision.uniconnect.android.data

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import com.unixcision.uniconnect.android.domain.BoxOverrides
import com.unixcision.uniconnect.android.domain.BoxOverridesRepository
import kotlinx.coroutines.flow.first
import org.json.JSONArray
import org.json.JSONObject

/** One JSON document per machine; an empty override removes the entry. */
class StoredBoxOverridesRepository(private val store: DataStore<Preferences>) : BoxOverridesRepository {
    private fun key(machineID: String) = stringPreferencesKey("box_overrides.v1.$machineID")

    override suspend fun load(machineID: String): BoxOverrides {
        val raw = store.data.first()[key(machineID)] ?: return BoxOverrides()
        return runCatching { decode(JSONObject(raw)) }.getOrDefault(BoxOverrides())
    }

    override suspend fun save(machineID: String, overrides: BoxOverrides) {
        store.edit { preferences ->
            if (overrides.isEmpty) preferences.remove(key(machineID)) else preferences[key(machineID)] = encode(overrides).toString()
        }
    }

    private fun encode(overrides: BoxOverrides) = JSONObject()
        .put("pinnedWorkspaces", JSONArray(overrides.pinnedWorkspaces.toList()))
        .put("pinnedWindows", JSONArray(overrides.pinnedWindows.toList()))
        .put("workspaceOrder", JSONArray(overrides.workspaceOrder))
        .put("windowOrder", JSONObject().apply { overrides.windowOrder.forEach { (id, order) -> put(id, JSONArray(order)) } })

    private fun decode(json: JSONObject): BoxOverrides {
        fun strings(array: JSONArray?) = array?.let { a -> List(a.length()) { a.getString(it) } } ?: emptyList()
        val windowOrder = json.optJSONObject("windowOrder")?.let { obj -> obj.keys().asSequence().associateWith { strings(obj.getJSONArray(it)) } } ?: emptyMap()
        return BoxOverrides(strings(json.optJSONArray("pinnedWorkspaces")).toSet(), strings(json.optJSONArray("pinnedWindows")).toSet(), strings(json.optJSONArray("workspaceOrder")), windowOrder)
    }
}
