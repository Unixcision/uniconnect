package com.unixcision.uniconnect.android.ui

import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.unixcision.uniconnect.android.data.ContentReader
import com.unixcision.uniconnect.android.domain.AttachPaste
import com.unixcision.uniconnect.android.domain.AttachRoute
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
 * the private connection (`file_put.v1`) and comes back as a path; when the host cannot take it,
 * the sheet says so and the file goes to the fallback service of the settings, coming back as a
 * link. What
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

    /** One picked file on its way to a path or a link for one window. */
    data class Transfer(
        val id: String,
        val uri: Uri,
        val target: AttachTarget,
        val route: AttachRoute,
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
        val isLink: Boolean get() = route == AttachRoute.EXTERNAL
        val fraction: Float get() = if (size <= 0) 1f else (sent.toFloat() / size).coerceIn(0f, 1f)
    }

    data class State(
        val transfers: List<Transfer> = emptyList(),
        /** The fallback service of the terminal's clip, from the settings. */
        val service: UploadService = UploadService.default,
    )

    private val mutableState = MutableStateFlow(State())
    val state = mutableState.asStateFlow()
    private var worker: Job? = null

    init {
        viewModelScope.launch { settingsRepository.settings.collect { stored -> mutableState.update { it.copy(service = stored.terminalUpload) } } }
    }

    /**
     * Queues [uris] for [target] by [route] and starts sending if nothing is on its way. With a
     * [refusal] the files are listed as failed with that reason and nothing is sent: the route
     * the reader saw is no longer possible and no other is taken for them.
     */
    fun attach(target: AttachTarget, uris: List<Uri>, route: AttachRoute, refusal: Throwable? = null) {
        if (uris.isEmpty()) return
        viewModelScope.launch(Dispatchers.IO) {
            val described = uris.map { uri ->
                runCatching { reader.describe(uri) }.fold(
                    onSuccess = {
                        if (refusal == null) Transfer(UUID.randomUUID().toString(), uri, target, route, it.name, it.size)
                        else Transfer(UUID.randomUUID().toString(), uri, target, route, it.name, it.size, status = Status.FAILED, failure = refusal)
                    },
                    onFailure = { Transfer(UUID.randomUUID().toString(), uri, target, route, uri.lastPathSegment ?: "", 0, status = Status.FAILED, failure = refusal ?: UploadFailure.Unreadable(uri.lastPathSegment ?: uri.toString())) },
                )
            }
            mutableState.update { it.copy(transfers = it.transfers + described) }
            if (refusal == null) startWorker()
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
                AttachRoute.HOST -> {
                    val outcome = filePut.withSession(transfer.target.machine) { session ->
                        FilePutTransfer.run(session, transfer.target.workspaceID, transfer.target.windowID, transfer.name, transfer.size, reader.mimeType(transfer.uri), { reader.open(transfer.uri) }, progress)
                    }
                    val pasteable = AttachPaste.shouldPaste(outcome.location, transfer.target.isSSH, outcome.remoteError)
                    update(transfer.id) { it.copy(status = Status.DONE, sent = transfer.size, reference = outcome.pastePath, pasteable = pasteable, remoteError = outcome.remoteError) }
                }
                AttachRoute.EXTERNAL -> {
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
