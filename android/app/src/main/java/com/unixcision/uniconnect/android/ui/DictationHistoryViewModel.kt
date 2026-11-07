package com.unixcision.uniconnect.android.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.DictationHistory
import com.unixcision.uniconnect.android.domain.DictationRecord
import com.unixcision.uniconnect.android.domain.DictationRetranscription
import com.unixcision.uniconnect.android.domain.HostTranscription
import com.unixcision.uniconnect.android.domain.Machine
import com.unixcision.uniconnect.android.domain.MachineRepository
import com.unixcision.uniconnect.android.domain.PhoneTranscriber
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.stateIn
import com.unixcision.uniconnect.android.domain.SentMessage
import com.unixcision.uniconnect.android.domain.SentMessageHistory
import kotlinx.coroutines.CompletableDeferred
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
 * The history for the screen: dictations (the list as it changes, deletions off the main thread
 * and «Volver a transcribir» with its progress and failure per entry) and the messages sent from
 * the composer, each kept before it leaves and settled with whether it arrived.
 */
class DictationHistoryViewModel(
    private val history: DictationHistory,
    transcription: HostTranscription? = null,
    private val machines: MachineRepository? = null,
    private val sent: SentMessageHistory? = null,
    /** Whisper on this phone, offered as one more place to transcribe a kept recording. */
    phone: PhoneTranscriber? = null,
) : ViewModel() {
    val records: StateFlow<List<DictationRecord>> = history.records

    /** Messages sent from the composer, newest first; empty without a store. */
    val sentMessages: StateFlow<List<SentMessage>> = sent?.messages ?: MutableStateFlow(emptyList<SentMessage>()).asStateFlow()

    // One writer at a time, in order: a message is always kept before its answer settles it.
    private val sentWrites = Dispatchers.IO.limitedParallelism(1)

    /**
     * Keeps [text] as sent to [windowName] on [machineName] and returns what to call with whether
     * it arrived. The disk is written off the main thread, in the order of the calls.
     */
    fun recordSent(text: String, withEnter: Boolean, machineName: String?, windowName: String?): (Boolean) -> Unit {
        val store = sent ?: return {}
        val id = CompletableDeferred<String>()
        viewModelScope.launch(sentWrites) { id.complete(store.record(text, withEnter, machineName, windowName)) }
        return { delivered -> viewModelScope.launch(sentWrites) { store.settle(id.await(), delivered) } }
    }

    fun deleteSent(ids: Set<String>) {
        val store = sent ?: return
        if (ids.isNotEmpty()) viewModelScope.launch(sentWrites) { store.delete(ids) }
    }

    fun clearSent() {
        val store = sent ?: return
        viewModelScope.launch(sentWrites) { store.clear() }
    }

    private val retranscription = transcription?.let { engine ->
        DictationRetranscription(history, engine, phone) { path -> runCatching { File(path).readBytes() }.getOrNull() }
    }

    /** The saved machines, for «Volver a transcribir en…». */
    val savedMachines: StateFlow<List<Machine>> =
        machines?.machines?.stateIn(viewModelScope, SharingStarted.Eagerly, emptyList()) ?: MutableStateFlow(emptyList<Machine>()).asStateFlow()

    /** Whether «En este móvil» can be offered now: the engine loads and a model is downloaded. */
    val phoneCanTranscribe: Boolean get() = retranscription?.phoneReady == true
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
        val saved = machines ?: return
        retranscribeWith(record) { engine ->
            engine.run(record, DictationRetranscription.machinesFor(record, saved.machines.first(), preferredMachineID), language)
        }
    }

    /** Sends the kept audio of [record] to [machine] only, the one the reader picked. */
    fun retranscribeOn(record: DictationRecord, language: String?, machine: Machine) =
        retranscribeWith(record) { engine -> engine.run(record, machine, language) }

    /** Reads the kept audio of [record] with Whisper on this phone. */
    fun retranscribeOnPhone(record: DictationRecord, language: String?) =
        retranscribeWith(record) { engine -> engine.runOnPhone(record, language) }

    private fun retranscribeWith(record: DictationRecord, work: suspend (DictationRetranscription) -> String) {
        val engine = retranscription ?: return
        if (record.id in busyIds.value) return
        busyIds.update { it + record.id }
        failures.update { it - record.id }
        viewModelScope.launch(Dispatchers.IO) {
            try {
                work(engine)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                val reason = when (failure) {
                    is DictationRetranscription.MissingAudio -> R.string.dictation_retranscribe_no_audio
                    is DictationRetranscription.NoPhoneEngine -> R.string.dictation_retranscribe_no_phone
                    else -> R.string.dictation_retranscribe_failed
                }
                failures.update { it + (record.id to reason) }
            } finally {
                busyIds.update { it - record.id }
            }
        }
    }
}
