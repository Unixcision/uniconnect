package com.unixcision.uniconnect.android.data

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import com.unixcision.uniconnect.android.domain.AppSettings
import com.unixcision.uniconnect.android.domain.SettingsRepository
import com.unixcision.uniconnect.android.domain.TerminalView
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map

/** Preferences kept beside the machine list; a missing value reads as the shipped default. */
class StoredSettingsRepository(private val store: DataStore<Preferences>) : SettingsRepository {
    private val view = stringPreferencesKey("settings.terminalView")
    private val keys = booleanPreferencesKey("settings.showExtraKeys")
    private val probe = booleanPreferencesKey("settings.probeOnOpen")
    private val defaults = AppSettings()

    override val settings = store.data.map { stored ->
        AppSettings(
            terminalView = TerminalView.named(stored[view]),
            showExtraKeys = stored[keys] ?: defaults.showExtraKeys,
            probeOnOpen = stored[probe] ?: defaults.probeOnOpen,
        )
    }.distinctUntilChanged()

    override suspend fun update(settings: AppSettings) {
        store.edit { preferences ->
            preferences[view] = settings.terminalView.name
            preferences[keys] = settings.showExtraKeys
            preferences[probe] = settings.probeOnOpen
        }
    }
}
