package com.unixcision.uniconnect.android.data

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import com.unixcision.uniconnect.android.domain.DraftRepository
import kotlinx.coroutines.flow.first

/** One preference per window; an empty draft removes the entry instead of storing "". */
class StoredDraftRepository(private val store: DataStore<Preferences>) : DraftRepository {
    private fun key(machineID: String, windowID: String) = stringPreferencesKey("draft.v1.$machineID/$windowID")

    override suspend fun load(machineID: String, windowID: String): String =
        store.data.first()[key(machineID, windowID)].orEmpty()

    override suspend fun save(machineID: String, windowID: String, text: String) {
        store.edit { preferences ->
            if (text.isEmpty()) preferences.remove(key(machineID, windowID)) else preferences[key(machineID, windowID)] = text
        }
    }
}
