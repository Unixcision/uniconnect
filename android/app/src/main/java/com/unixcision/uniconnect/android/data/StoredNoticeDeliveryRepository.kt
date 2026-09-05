package com.unixcision.uniconnect.android.data

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import com.unixcision.uniconnect.android.domain.NoticeDeliveryRepository
import kotlinx.coroutines.flow.first
import org.json.JSONArray
import org.json.JSONObject

/** Stores bounded delivery IDs, never titles, bodies, terminal text or credentials. */
class StoredNoticeDeliveryRepository(private val store: DataStore<Preferences>) : NoticeDeliveryRepository {
    private val key = stringPreferencesKey("delivered_notices.v1")
    override suspend fun deliveredIDs(machineID: String): Set<String> {
        val root = JSONObject(store.data.first()[key] ?: "{}")
        val entries = root.optJSONArray(machineID) ?: return emptySet()
        return List(entries.length()) { entries.getString(it) }.toSet()
    }

    override suspend fun remember(machineID: String, noticeID: String) {
        store.edit { preferences ->
            val root = JSONObject(preferences[key] ?: "{}")
            val previous = root.optJSONArray(machineID) ?: JSONArray()
            val entries = (List(previous.length()) { previous.getString(it) }.filterNot { it == noticeID } + noticeID).takeLast(4096)
            root.put(machineID, JSONArray(entries))
            preferences[key] = root.toString()
        }
    }
}
