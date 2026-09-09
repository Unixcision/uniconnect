package com.unixcision.uniconnect.android.data

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import com.unixcision.uniconnect.android.domain.AppSettings
import com.unixcision.uniconnect.android.domain.ColorMode
import com.unixcision.uniconnect.android.domain.DesignTheme
import com.unixcision.uniconnect.android.domain.SettingsRepository
import com.unixcision.uniconnect.android.domain.TerminalView
import com.unixcision.uniconnect.android.domain.UploadService
import com.unixcision.uniconnect.android.domain.UploadStyle
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map

/**
 * Preferences kept beside the machine list; a missing value reads as the shipped default.
 *
 * Every preference has its own key, so a store written by an older build, before the appearance
 * or upload keys existed, still reads: the old values are kept and the new ones take their defaults.
 */
class StoredSettingsRepository(private val store: DataStore<Preferences>) : SettingsRepository {
    private val view = stringPreferencesKey("settings.terminalView")
    private val keys = booleanPreferencesKey("settings.showExtraKeys")
    private val probe = booleanPreferencesKey("settings.probeOnOpen")
    private val theme = stringPreferencesKey("settings.designTheme")
    private val mode = stringPreferencesKey("settings.colorMode")
    private val uploadDomain = stringPreferencesKey("settings.uploadDomain")
    private val uploadStyle = stringPreferencesKey("settings.uploadStyle")
    private val terminalUploadDomain = stringPreferencesKey("settings.terminalUploadDomain")
    private val terminalUploadStyle = stringPreferencesKey("settings.terminalUploadStyle")
    private val defaults = AppSettings()

    override val settings = store.data.map { stored ->
        AppSettings(
            terminalView = TerminalView.named(stored[view]),
            showExtraKeys = stored[keys] ?: defaults.showExtraKeys,
            probeOnOpen = stored[probe] ?: defaults.probeOnOpen,
            designTheme = DesignTheme.named(stored[theme]),
            colorMode = ColorMode.named(stored[mode]),
            uploadService = service(stored[uploadDomain], stored[uploadStyle]) ?: defaults.uploadService,
            terminalUploadService = service(stored[terminalUploadDomain], stored[terminalUploadStyle]),
        )
    }.distinctUntilChanged()

    override suspend fun update(settings: AppSettings) {
        store.edit { preferences ->
            preferences[view] = settings.terminalView.name
            preferences[keys] = settings.showExtraKeys
            preferences[probe] = settings.probeOnOpen
            preferences[theme] = settings.designTheme.name
            preferences[mode] = settings.colorMode.name
            preferences[uploadDomain] = settings.uploadService.domain
            preferences[uploadStyle] = settings.uploadService.style.name
            val terminal = settings.terminalUploadService
            if (terminal == null) {
                preferences.remove(terminalUploadDomain)
                preferences.remove(terminalUploadStyle)
            } else {
                preferences[terminalUploadDomain] = terminal.domain
                preferences[terminalUploadStyle] = terminal.style.name
            }
        }
    }

    /** A stored domain and style as a service; no domain means nothing was chosen. */
    private fun service(domain: String?, style: String?): UploadService? =
        domain?.takeIf { it.isNotBlank() }?.let { UploadService(it, UploadStyle.named(style)) }
}
