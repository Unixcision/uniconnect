package com.unixcision.uniconnect.android.data

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import com.unixcision.uniconnect.android.domain.UploadHistoryRepository
import com.unixcision.uniconnect.android.domain.UploadResult
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import org.json.JSONArray
import org.json.JSONObject

/** One JSON array under one key, newest first; an unreadable entry is skipped, not fatal. */
class StoredUploadHistoryRepository(private val store: DataStore<Preferences>) : UploadHistoryRepository {
    private val key = stringPreferencesKey("uploads.history.v1")

    override val history = store.data.map { decode(it[key]) }.distinctUntilChanged()

    override suspend fun add(result: UploadResult) {
        store.edit { preferences ->
            val kept = (listOf(result) + decode(preferences[key]).filter { it.link != result.link }).take(UploadHistoryRepository.LIMIT)
            preferences[key] = encode(kept)
        }
    }

    override suspend fun remove(link: String) {
        store.edit { preferences ->
            val kept = decode(preferences[key]).filter { it.link != link }
            if (kept.isEmpty()) preferences.remove(key) else preferences[key] = encode(kept)
        }
    }

    private fun encode(results: List<UploadResult>): String = JSONArray().apply {
        results.forEach { put(JSONObject().put("link", it.link).put("name", it.name).put("size", it.size).put("uploadedAt", it.uploadedAt)) }
    }.toString()

    private fun decode(raw: String?): List<UploadResult> {
        val array = raw?.let { runCatching { JSONArray(it) }.getOrNull() } ?: return emptyList()
        return (0 until array.length()).mapNotNull { index ->
            val entry = array.optJSONObject(index) ?: return@mapNotNull null
            val link = entry.optString("link").takeIf { it.isNotEmpty() } ?: return@mapNotNull null
            UploadResult(link, entry.optString("name"), entry.optLong("size"), entry.optLong("uploadedAt"))
        }
    }
}
