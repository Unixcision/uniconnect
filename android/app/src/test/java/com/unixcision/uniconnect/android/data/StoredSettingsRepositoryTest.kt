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
import com.unixcision.uniconnect.android.domain.DictationLanguage
import com.unixcision.uniconnect.android.domain.TerminalView
import com.unixcision.uniconnect.android.domain.TranscriptionMode
import com.unixcision.uniconnect.android.domain.UploadService
import com.unixcision.uniconnect.android.domain.UploadStyle
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
    fun theUploadServiceSurvivesARoundTripAndDefaultsToSendit() = runBlocking {
        val repository = StoredSettingsRepository(MemoryPreferences())
        assertEquals(UploadService("sendit.sh", UploadStyle.RAW_NAMED), repository.settings.first().uploadService)
        val custom = UploadService("archivos.midominio.com", UploadStyle.MULTIPART_FILE)
        repository.update(AppSettings(uploadService = custom))
        assertEquals(custom, repository.settings.first().uploadService)
        repository.update(AppSettings(uploadService = UploadService.presets[2]))
        assertEquals(UploadStyle.LITTERBOX, repository.settings.first().uploadService.style)
    }

    @Test
    fun theTerminalFallbackIsKeptApartAndFollowsThePageUntilChosen() = runBlocking {
        val repository = StoredSettingsRepository(MemoryPreferences())
        val page = UploadService("temp.sh", UploadStyle.MULTIPART_FILE)
        repository.update(AppSettings(uploadService = page))
        val stored = repository.settings.first()
        assertEquals(null, stored.terminalUploadService)
        assertEquals(page, stored.terminalUpload)
        val own = UploadService("https://mi.servidor.com/api/upload", UploadStyle.RAW_NAMED)
        repository.update(stored.copy(terminalUploadService = own))
        val chosen = repository.settings.first()
        assertEquals(own, chosen.terminalUploadService)
        assertEquals(page, chosen.uploadService)
        repository.update(chosen.copy(terminalUploadService = null))
        assertEquals(page, repository.settings.first().terminalUpload)
    }

    @Test
    fun theVoiceSettingsSurviveARoundTripAndDefaultToOffAndTheDevice() = runBlocking {
        val repository = StoredSettingsRepository(MemoryPreferences())
        val fresh = repository.settings.first()
        assertEquals(false, fresh.sendOnDictationEnd)
        assertEquals(DictationLanguage.DEVICE, fresh.dictationLanguage)
        repository.update(fresh.copy(sendOnDictationEnd = true, dictationLanguage = DictationLanguage.ES_ES))
        val stored = repository.settings.first()
        assertEquals(true, stored.sendOnDictationEnd)
        assertEquals(DictationLanguage.ES_ES, stored.dictationLanguage)
    }

    @Test
    fun theWayOfTranscribingSurvivesARoundTripAndDefaultsToAutomatic() = runBlocking {
        val repository = StoredSettingsRepository(MemoryPreferences())
        assertEquals(TranscriptionMode.AUTO, repository.settings.first().transcription)
        repository.update(repository.settings.first().copy(transcription = TranscriptionMode.HOST))
        assertEquals(TranscriptionMode.HOST, repository.settings.first().transcription)
        repository.update(repository.settings.first().copy(transcription = TranscriptionMode.PHONE))
        assertEquals(TranscriptionMode.PHONE, repository.settings.first().transcription)
    }

    @Test
    fun aStoreFromBeforeTranscriptionExistedKeepsItsVoiceSettings() = runBlocking {
        val older = preferencesOf(
            booleanPreferencesKey("settings.sendOnDictationEnd") to true,
            stringPreferencesKey("settings.dictationLanguage") to "ES_ES",
        )
        val stored = StoredSettingsRepository(MemoryPreferences(older)).settings.first()
        assertEquals(true, stored.sendOnDictationEnd)
        assertEquals(DictationLanguage.ES_ES, stored.dictationLanguage)
        assertEquals(TranscriptionMode.AUTO, stored.transcription)
    }

    @Test
    fun aStoredDomainWithAnUnknownStyleReadsAsRaw() = runBlocking {
        val stored = preferencesOf(
            stringPreferencesKey("settings.uploadDomain") to "temp.sh",
            stringPreferencesKey("settings.uploadStyle") to "PIGEON",
        )
        assertEquals(UploadService("temp.sh", UploadStyle.RAW_NAMED), StoredSettingsRepository(MemoryPreferences(stored)).settings.first().uploadService)
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
