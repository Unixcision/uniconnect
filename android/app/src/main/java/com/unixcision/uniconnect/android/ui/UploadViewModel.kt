package com.unixcision.uniconnect.android.ui

import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.unixcision.uniconnect.android.data.ContentReader
import com.unixcision.uniconnect.android.domain.AppSettings
import com.unixcision.uniconnect.android.domain.FileSender
import com.unixcision.uniconnect.android.domain.SettingsRepository
import com.unixcision.uniconnect.android.domain.UploadFailure
import com.unixcision.uniconnect.android.domain.UploadHistoryRepository
import com.unixcision.uniconnect.android.domain.UploadResult
import com.unixcision.uniconnect.android.domain.UploadService
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.util.UUID

/**
 * The "Enviar archivos" section: picked files go into a queue and are sent one after another to
 * the service in the settings; each link is shown and kept in the history. Nothing is retried on
 * its own, and a failed upload stays on screen with its reason until the reader retries or
 * dismisses it.
 */
class UploadViewModel(
    private val sender: FileSender,
    private val settingsRepository: SettingsRepository,
    private val historyRepository: UploadHistoryRepository,
    private val reader: ContentReader,
) : ViewModel() {
    enum class Status { PENDING, UPLOADING, DONE, FAILED }

    /** One picked file and where it is on its way to a link. */
    data class Upload(
        val id: String,
        val uri: Uri,
        val name: String,
        val size: Long,
        val sent: Long = 0,
        val status: Status = Status.PENDING,
        val link: String? = null,
        val failure: UploadFailure? = null,
    ) {
        /** 0 to 1 of the bytes sent; an empty file counts as done the moment it starts. */
        val fraction: Float get() = if (size <= 0) 1f else (sent.toFloat() / size).coerceIn(0f, 1f)
    }

    data class State(
        /** Where files go; the stored setting, or the default until it is read. */
        val service: UploadService = UploadService.default,
        /** Files picked in this session, oldest first, in every status. */
        val uploads: List<Upload> = emptyList(),
        /** Links obtained before, newest first. */
        val history: List<UploadResult> = emptyList(),
    )

    private val mutableState = MutableStateFlow(State())
    val state = mutableState.asStateFlow()
    private var settings = AppSettings()
    private var worker: Job? = null

    init {
        viewModelScope.launch {
            settingsRepository.settings.collect { stored ->
                settings = stored
                mutableState.update { it.copy(service = stored.uploadService) }
            }
        }
        viewModelScope.launch { historyRepository.history.collect { kept -> mutableState.update { it.copy(history = kept) } } }
    }

    /** Queues [uris] as picked, in order, and starts sending if nothing is being sent. */
    fun enqueue(uris: List<Uri>) {
        if (uris.isEmpty()) return
        viewModelScope.launch(Dispatchers.IO) {
            val described = uris.map { uri ->
                runCatching { reader.describe(uri) }.fold(
                    onSuccess = { Upload(UUID.randomUUID().toString(), uri, it.name, it.size) },
                    onFailure = { Upload(UUID.randomUUID().toString(), uri, uri.lastPathSegment ?: "", 0, status = Status.FAILED, failure = UploadFailure.Unreadable(uri.lastPathSegment ?: uri.toString())) },
                )
            }
            mutableState.update { it.copy(uploads = it.uploads + described) }
            startWorker()
        }
    }

    /** Sends a failed upload again from its first byte. */
    fun retry(id: String) {
        mutableState.update { state -> state.copy(uploads = state.uploads.map { if (it.id == id && it.status == Status.FAILED) it.copy(status = Status.PENDING, sent = 0, failure = null) else it }) }
        startWorker()
    }

    /** Takes an upload off the screen; one in flight is aborted. */
    fun dismiss(id: String) {
        val inFlight = state.value.uploads.firstOrNull { it.id == id }?.status == Status.UPLOADING
        mutableState.update { state -> state.copy(uploads = state.uploads.filterNot { it.id == id }) }
        if (inFlight) {
            worker?.cancel()
            worker = null
            startWorker()
        }
    }

    /** Stores [service] with the other settings; the next upload goes there. */
    fun setService(service: UploadService) {
        viewModelScope.launch { settingsRepository.update(settings.copy(uploadService = service)) }
    }

    /** Forgets a link from the history. */
    fun removeFromHistory(link: String) {
        viewModelScope.launch { historyRepository.remove(link) }
    }

    /** One worker at a time: files go in sequence, so a slow service does not multiply itself. */
    private fun startWorker() {
        if (worker?.isActive == true) return
        worker = viewModelScope.launch(Dispatchers.IO) {
            while (true) {
                val next = state.value.uploads.firstOrNull { it.status == Status.PENDING } ?: break
                send(next)
            }
        }
    }

    private suspend fun send(upload: Upload) {
        val service = state.value.service
        update(upload.id) { it.copy(status = Status.UPLOADING, sent = 0, failure = null) }
        var lastShown = 0L
        try {
            val link = sender.send(service, upload.name, upload.size, { reader.open(upload.uri) }) { sent ->
                // Progress arrives per chunk; the screen only needs it every so often or at the end.
                if (sent - lastShown >= PROGRESS_STEP || sent >= upload.size) {
                    lastShown = sent
                    update(upload.id) { it.copy(sent = sent) }
                }
            }
            update(upload.id) { it.copy(status = Status.DONE, sent = upload.size, link = link) }
            historyRepository.add(UploadResult(link, upload.name, upload.size, System.currentTimeMillis()))
        } catch (e: CancellationException) {
            throw e
        } catch (e: UploadFailure) {
            update(upload.id) { it.copy(status = Status.FAILED, failure = e) }
        } catch (e: Exception) {
            update(upload.id) { it.copy(status = Status.FAILED, failure = UploadFailure.Unreachable(service.domain)) }
        }
    }

    private fun update(id: String, change: (Upload) -> Upload) {
        mutableState.update { state -> state.copy(uploads = state.uploads.map { if (it.id == id) change(it) else it }) }
    }

    private companion object {
        const val PROGRESS_STEP = 128L * 1024
    }
}
