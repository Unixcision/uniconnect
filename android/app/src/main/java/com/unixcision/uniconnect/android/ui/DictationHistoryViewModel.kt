package com.unixcision.uniconnect.android.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.DictationHistory
import com.unixcision.uniconnect.android.domain.DictationRecord
import com.unixcision.uniconnect.android.domain.DictationRetranscription
import com.unixcision.uniconnect.android.domain.HostTranscription
import com.unixcision.uniconnect.android.domain.MachineRepository
import java.io.File
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * The dictation history for the screen: the list as it changes, deletions off the main thread and
 * «Volver a transcribir» with its progress and failure per entry.
 */
class DictationHistoryViewModel(
    private val history: DictationHistory,
    transcription: HostTranscription? = null,
    private val machines: MachineRepository? = null,
) : ViewModel() {
    val records: StateFlow<List<DictationRecord>> = history.records

    private val retranscription = transcription?.let { engine ->
        DictationRetranscription(history, engine) { path -> runCatching { File(path).readBytes() }.getOrNull() }
    }
    private val busyIds = MutableStateFlow<Set<String>>(emptySet())
    /** Entries being transcribed again right now. */
    val busy: StateFlow<Set<String>> = busyIds.asStateFlow()
    private val failures = MutableStateFlow<Map<String, Int>>(emptyMap())
    /** Why the last «Volver a transcribir» of an entry failed, as a string resource. */
    val failed: StateFlow<Map<String, Int>> = failures.asStateFlow()

    val canRetranscribe: Boolean get() = retranscription != null && machines != null

    fun delete(ids: Set<String>) {
        if (ids.isNotEmpty()) viewModelScope.launch(Dispatchers.IO) { history.delete(ids) }
    }

    fun deleteAudio(ids: Set<String>) {
        if (ids.isNotEmpty()) viewModelScope.launch(Dispatchers.IO) { history.deleteAudio(ids) }
    }

    /**
     * Sends the kept audio of [record] to be transcribed again; the new text replaces the old one.
     *
     * - Parameter preferredMachineID: the transcriber picked in Ajustes, tried first; then the
     *   machine it was dictated for and every other one, past those with no engine or no answer.
     */
    fun retranscribe(record: DictationRecord, language: String?, preferredMachineID: String? = null) {
        val engine = retranscription ?: return
        val saved = machines ?: return
        if (record.id in busyIds.value) return
        busyIds.update { it + record.id }
        failures.update { it - record.id }
        viewModelScope.launch(Dispatchers.IO) {
            try {
                val order = DictationRetranscription.machinesFor(record, saved.machines.first(), preferredMachineID)
                engine.run(record, order, language)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                val reason = if (failure is DictationRetranscription.MissingAudio) R.string.dictation_retranscribe_no_audio
                    else R.string.dictation_retranscribe_failed
                failures.update { it + (record.id to reason) }
            } finally {
                busyIds.update { it - record.id }
            }
        }
    }
}
