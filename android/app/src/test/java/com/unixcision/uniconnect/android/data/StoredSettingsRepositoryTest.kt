package com.unixcision.uniconnect.android.data

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.emptyPreferences
import androidx.datastore.preferences.core.preferencesOf
import androidx.datastore.preferences.core.stringPreferencesKey
import com.unixcision.uniconnect.android.domain.AppSettings
import com.unixcision.uniconnect.android.domain.ColorMode
import com.unixcision.uniconnect.android.domain.DesignTheme
import com.unixcision.uniconnect.android.domain.TerminalView
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The preferences survive a round trip, and a store written before the appearance keys existed
 * still reads with the old values kept and the new ones at their defaults.
 */
class StoredSettingsRepositoryTest {
    @Test
    fun themeAndModeSurviveARoundTrip() = runBlocking {
        val repository = StoredSettingsRepository(MemoryPreferences())
        val chosen = AppSettings(terminalView = TerminalView.WRAP, showExtraKeys = true, probeOnOpen = false, designTheme = DesignTheme.TINTA, colorMode = ColorMode.DARK)
        repository.update(chosen)
        assertEquals(chosen, repository.settings.first())
        val again = chosen.copy(designTheme = DesignTheme.TERMINAL, colorMode = ColorMode.LIGHT)
        repository.update(again)
        assertEquals(again, repository.settings.first())
    }

    @Test
    fun anEmptyStoreReadsAsTheShippedDefaults() = runBlocking {
        val repository = StoredSettingsRepository(MemoryPreferences())
        assertEquals(AppSettings(), repository.settings.first())
        assertEquals(DesignTheme.SERENO, repository.settings.first().designTheme)
        assertEquals(ColorMode.SYSTEM, repository.settings.first().colorMode)
    }

    @Test
    fun aStoreFromBeforeTheAppearanceKeysKeepsItsOldValues() = runBlocking {
        val older = preferencesOf(
            stringPreferencesKey("settings.terminalView") to "FIT",
            booleanPreferencesKey("settings.showExtraKeys") to true,
            booleanPreferencesKey("settings.probeOnOpen") to false,
        )
        val repository = StoredSettingsRepository(MemoryPreferences(older))
        assertEquals(
            AppSettings(terminalView = TerminalView.FIT, showExtraKeys = true, probeOnOpen = false, designTheme = DesignTheme.SERENO, colorMode = ColorMode.SYSTEM),
            repository.settings.first(),
        )
    }

    @Test
    fun unknownStoredNamesFallBackInsteadOfFailing() = runBlocking {
        val stored = preferencesOf(
            stringPreferencesKey("settings.designTheme") to "NEON",
            stringPreferencesKey("settings.colorMode") to "AUTO",
        )
        val repository = StoredSettingsRepository(MemoryPreferences(stored))
        assertEquals(DesignTheme.SERENO, repository.settings.first().designTheme)
        assertEquals(ColorMode.SYSTEM, repository.settings.first().colorMode)
    }

    /** A preferences store that lives in memory: same contract, nothing on disk. */
    private class MemoryPreferences(initial: Preferences = emptyPreferences()) : DataStore<Preferences> {
        private val state = MutableStateFlow(initial)
        override val data: Flow<Preferences> get() = state
        override suspend fun updateData(transform: suspend (t: Preferences) -> Preferences): Preferences {
            val next = transform(state.value)
            state.value = next
            return next
        }
    }
}
