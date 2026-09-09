package com.unixcision.uniconnect.android.data

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.emptyPreferences
import com.unixcision.uniconnect.android.domain.UploadHistoryRepository
import com.unixcision.uniconnect.android.domain.UploadResult
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test

/** Links are kept newest first, capped, and forgotten one by one. */
class StoredUploadHistoryRepositoryTest {
    private fun result(n: Int) = UploadResult("https://sendit.sh/x/$n.txt", "$n.txt", n * 10L, 1_000L + n)

    @Test
    fun theNewestLinkComesFirstAndSurvivesARoundTrip() = runBlocking {
        val repository = StoredUploadHistoryRepository(MemoryPreferences())
        repository.add(result(1))
        repository.add(result(2))
        assertEquals(listOf(result(2), result(1)), repository.history.first())
    }

    @Test
    fun onlyTheLastThirtyAreKept() = runBlocking {
        val repository = StoredUploadHistoryRepository(MemoryPreferences())
        (1..35).forEach { repository.add(result(it)) }
        val kept = repository.history.first()
        assertEquals(UploadHistoryRepository.LIMIT, kept.size)
        assertEquals(result(35), kept.first())
        assertEquals(result(6), kept.last())
    }

    @Test
    fun aRepeatedLinkMovesToTheFrontInsteadOfDoubling() = runBlocking {
        val repository = StoredUploadHistoryRepository(MemoryPreferences())
        repository.add(result(1))
        repository.add(result(2))
        repository.add(result(1))
        assertEquals(listOf(result(1), result(2)), repository.history.first())
    }

    @Test
    fun removingForgetsOneLink() = runBlocking {
        val repository = StoredUploadHistoryRepository(MemoryPreferences())
        repository.add(result(1))
        repository.add(result(2))
        repository.remove(result(2).link)
        assertEquals(listOf(result(1)), repository.history.first())
        repository.remove(result(1).link)
        assertEquals(emptyList<UploadResult>(), repository.history.first())
    }

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
