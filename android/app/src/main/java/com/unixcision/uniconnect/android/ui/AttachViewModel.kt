package com.unixcision.uniconnect.android.ui

import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.unixcision.uniconnect.android.data.ContentReader
import com.unixcision.uniconnect.android.domain.AttachPaste
import com.unixcision.uniconnect.android.domain.FilePutClient
import com.unixcision.uniconnect.android.domain.FilePutTransfer
import com.unixcision.uniconnect.android.domain.FileSender
import com.unixcision.uniconnect.android.domain.SettingsRepository
import com.unixcision.uniconnect.android.domain.UploadFailure
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
 * Attachments picked from a terminal window. By default each one goes to the window's host over
 * the private connection (`file_put.v1`) and comes back as a path; only on the reader's explicit
 * choice does one go to the transfer service of "Enviar archivos" and come back as a link. What
 * comes back is offered once for pasting into that window's composer when it sits where the
 * window's agent can read it; otherwise it is shown and kept for copying.
 */
class AttachViewModel(
    private val filePut: FilePutClient,
    private val sender: FileSender,
    settingsRepository: SettingsRepository,
    private val reader: ContentReader,
) : ViewModel() {
    enum class Status { PENDING, SENDING, DONE, FAILED }

    /** Where a file goes: the window's host over the private connection, or an external service. */
    enum class Route { HOST, EXTERNAL }

    /** One picked file on its way to a path or a link for one window. */
    data class Transfer(
        val id: String,
        val uri: Uri,
        val target: AttachTarget,
        val route: Route,
        val name: String,
        val size: Long,
        val sent: Long = 0,
        val status: Status = Status.PENDING,
        /** The path (host or remote) or the link, once done. */
        val reference: String? = null,
        /** Whether [reference] may go into the composer on its own; a host copy for an SSH window may not. */
        val pasteable: Boolean = true,
        /** The host kept the file but could not copy it to the SSH server. */
        val remoteError: String? = null,
        val failure: Throwable? = null,
        /** The screen has dealt with the result: pasted it, or told the reader it was kept. */
        val handled: Boolean = false,
    ) {
        val isLink: Boolean get() = route == Route.EXTERNAL
        val fraction: Float get() = if (size <= 0) 1f else (sent.toFloat() / size).coerceIn(0f, 1f)
    }

    data class State(
        val transfers: List<Transfer> = emptyList(),
        /** The transfer service used on the explicit external route. */
        val service: UploadService = UploadService.default,
    )

    private val mutableState = MutableStateFlow(State())
    val state = mutableState.asStateFlow()
    private var worker: Job? = null

    init {
        viewModelScope.launch { settingsRepository.settings.collect { stored -> mutableState.update { it.copy(service = stored.uploadService) } } }
    }

    /** Queues [uris] for [target] by [route] and starts sending if nothing is on its way. */
    fun attach(target: AttachTarget, uris: List<Uri>, route: Route) {
        if (uris.isEmpty()) return
        viewModelScope.launch(Dispatchers.IO) {
            val described = uris.map { uri ->
                runCatching { reader.describe(uri) }.fold(
                    onSuccess = { Transfer(UUID.randomUUID().toString(), uri, target, route, it.name, it.size) },
                    onFailure = { Transfer(UUID.randomUUID().toString(), uri, target, route, uri.lastPathSegment ?: "", 0, status = Status.FAILED, failure = UploadFailure.Unreadable(uri.lastPathSegment ?: uri.toString())) },
                )
            }
            mutableState.update { it.copy(transfers = it.transfers + described) }
            startWorker()
        }
    }

    /** The screen has pasted the reference or told the reader where it is; it is not offered again. */
    fun markHandled(id: String) = update(id) { it.copy(handled = true) }

    /** Sends a failed transfer again from its first byte. */
    fun retry(id: String) {
        mutableState.update { state -> state.copy(transfers = state.transfers.map { if (it.id == id && it.status == Status.FAILED) it.copy(status = Status.PENDING, sent = 0, failure = null) else it }) }
        startWorker()
    }

    /** Takes a transfer off the list; one in flight is aborted. */
    fun dismiss(id: String) {
        val inFlight = state.value.transfers.firstOrNull { it.id == id }?.status == Status.SENDING
        mutableState.update { state -> state.copy(transfers = state.transfers.filterNot { it.id == id }) }
        if (inFlight) {
            worker?.cancel()
            worker = null
            startWorker()
        }
    }

    private fun startWorker() {
        if (worker?.isActive == true) return
        worker = viewModelScope.launch(Dispatchers.IO) {
            while (true) {
                val next = state.value.transfers.firstOrNull { it.status == Status.PENDING } ?: break
                send(next)
            }
        }
    }

    private suspend fun send(transfer: Transfer) {
        update(transfer.id) { it.copy(status = Status.SENDING, sent = 0, failure = null) }
        var lastShown = 0L
        val progress: (Long) -> Unit = { sent ->
            if (sent - lastShown >= PROGRESS_STEP || sent >= transfer.size) {
                lastShown = sent
                update(transfer.id) { it.copy(sent = sent) }
            }
        }
        try {
            when (transfer.route) {
                Route.HOST -> {
                    val outcome = filePut.withSession(transfer.target.machine) { session ->
                        FilePutTransfer.run(session, transfer.target.workspaceID, transfer.target.windowID, transfer.name, transfer.size, reader.mimeType(transfer.uri), { reader.open(transfer.uri) }, progress)
                    }
                    val pasteable = AttachPaste.shouldPaste(outcome.location, transfer.target.isSSH)
                    update(transfer.id) { it.copy(status = Status.DONE, sent = transfer.size, reference = outcome.pastePath, pasteable = pasteable, remoteError = outcome.remoteError) }
                }
                Route.EXTERNAL -> {
                    val link = sender.send(state.value.service, transfer.name, transfer.size, { reader.open(transfer.uri) }, progress)
                    update(transfer.id) { it.copy(status = Status.DONE, sent = transfer.size, reference = link, pasteable = true) }
                }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            update(transfer.id) { it.copy(status = Status.FAILED, failure = e) }
        }
    }

    private fun update(id: String, change: (Transfer) -> Transfer) {
        mutableState.update { state -> state.copy(transfers = state.transfers.map { if (it.id == id) change(it) else it }) }
    }

    private companion object {
        const val PROGRESS_STEP = 128L * 1024
    }
}
