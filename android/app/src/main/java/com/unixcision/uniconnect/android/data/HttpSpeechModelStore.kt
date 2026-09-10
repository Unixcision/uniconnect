package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.SpeechModel
import com.unixcision.uniconnect.android.domain.SpeechModelFailure
import com.unixcision.uniconnect.android.domain.SpeechModelState
import com.unixcision.uniconnect.android.domain.SpeechModelStore
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * The Whisper models on this phone: what is there, what is being fetched, and nothing else.
 *
 * A model is only ever fetched because the reader asked for it. It is written next to the app's
 * own files, so uninstalling takes it away and no other app can read it, and it lands there under
 * a temporary name until it is whole: a finished file is one whose size is exactly the size the
 * model has and whose first four bytes are ggml's. Anything else is a failure that keeps what it
 * fetched, so a download cut halfway carries on rather than starting again.
 *
 * Everything platform-specific is a [File] and an [HttpURLConnection], which is why the whole of
 * it runs in a JVM test against a local server.
 *
 * ```kotlin
 * val store = HttpSpeechModelStore(File(context.filesDir, "whisper"), scope)
 * store.download(SpeechModel.BASE)
 * ```
 */
class HttpSpeechModelStore(
    private val directory: File,
    private val scope: CoroutineScope,
    private val base: String = SpeechModel.HOST,
    private val io: CoroutineDispatcher = Dispatchers.IO,
    /**
     * How big each model is, which is what a finished download is measured against. It is the
     * model's own published size everywhere but in a test, where serving two hundred megabytes to
     * prove that a resumed download reassembles would be absurd.
     */
    private val sizeOf: (SpeechModel) -> Long = SpeechModel::bytes,
) : SpeechModelStore {
    private val mutable = MutableStateFlow(scan())
    private val jobs = mutableMapOf<SpeechModel, Job>()

    override val states: StateFlow<Map<SpeechModel, SpeechModelState>> = mutable

    override val ready: SpeechModel? get() = SpeechModel.best(mutable.value.filterValues { it is SpeechModelState.Ready }.keys)

    override fun path(model: SpeechModel): String? = file(model).takeIf { mutable.value[model] is SpeechModelState.Ready }?.absolutePath

    override fun download(model: SpeechModel) {
        if (jobs[model]?.isActive == true) return
        if (mutable.value[model] is SpeechModelState.Ready) return
        val started = scope.launch {
            try {
                fetch(model)
            } catch (stopped: CancellationException) {
                // Whatever was fetched stays; the reader stopped it and may carry on later.
                publish(model, SpeechModelState.Paused(partial(model).length(), sizeOf(model)))
                throw stopped
            }
        }
        jobs[model] = started
        started.invokeOnCompletion { jobs.remove(model) }
    }

    override fun cancel(model: SpeechModel) {
        jobs.remove(model)?.cancel()
    }

    override fun delete(model: SpeechModel) {
        cancel(model)
        runCatching { file(model).delete() }
        runCatching { partial(model).delete() }
        publish(model, SpeechModelState.Missing)
    }

    /** The model's own file, whole and verified. */
    private fun file(model: SpeechModel) = File(directory, model.file)

    /** Where a download is written until it is whole. */
    private fun partial(model: SpeechModel) = File(directory, model.file + ".part")

    /** What is on disk right now, without touching the network. */
    private fun scan(): Map<SpeechModel, SpeechModelState> = SpeechModel.entries.associateWith { model ->
        val whole = File(directory, model.file)
        val half = File(directory, model.file + ".part")
        when {
            whole.isFile && whole.length() == sizeOf(model) -> SpeechModelState.Ready(whole.length())
            // A file of the wrong size is not the model, whatever it is; it is not offered as one.
            whole.isFile -> SpeechModelState.Failed(SpeechModelFailure.CORRUPT)
            half.isFile && half.length() > 0 -> SpeechModelState.Paused(half.length(), sizeOf(model))
            else -> SpeechModelState.Missing
        }
    }

    private fun publish(model: SpeechModel, state: SpeechModelState) {
        mutable.value = mutable.value + (model to state)
    }

    private suspend fun fetch(model: SpeechModel) = withContext(io) {
        val half = partial(model)
        val whole = file(model)
        if (!directory.isDirectory && !directory.mkdirs()) {
            publish(model, SpeechModelState.Failed(SpeechModelFailure.WRITE_FAILED))
            return@withContext
        }
        var have = if (half.isFile) half.length() else 0
        if (have > sizeOf(model)) {
            // Longer than the model itself: it is not a piece of it, so it starts again.
            runCatching { half.delete() }
            have = 0
        }
        if (have == sizeOf(model)) {
            // Every byte is already here and only the last step is missing: the app was killed
            // between the final byte and the rename. Asking the server to resume from the end of
            // the file earns an HTTP 416 and nothing else, for ever, so the download can never
            // finish; finish it here instead of going back to the network for nothing.
            finish(model, half, whole)
            return@withContext
        }
        val missing = sizeOf(model) - have
        if (directory.usableSpace in 0 until missing + HEADROOM_BYTES) {
            publish(model, SpeechModelState.Failed(SpeechModelFailure.NO_SPACE, have))
            return@withContext
        }
        publish(model, SpeechModelState.Downloading(have, sizeOf(model)))

        var connection: HttpURLConnection? = null
        try {
            val opened = (URL(base + model.file).openConnection() as HttpURLConnection).apply {
                connectTimeout = CONNECT_MILLIS
                readTimeout = READ_MILLIS
                instanceFollowRedirects = true
                setRequestProperty("Accept-Encoding", "identity")
                if (have > 0) setRequestProperty("Range", "bytes=$have-")
            }
            connection = opened
            val code = opened.responseCode
            val resumed = code == HttpURLConnection.HTTP_PARTIAL
            if (code == RANGE_NOT_SATISFIABLE) {
                // What is on disk does not match what the server is willing to send from. Whatever
                // it is, it is not a piece of this file: dropping it is the only way forward.
                runCatching { half.delete() }
                publish(model, SpeechModelState.Failed(SpeechModelFailure.CORRUPT, 0, "HTTP $code"))
                return@withContext
            }
            if (code != HttpURLConnection.HTTP_OK && !resumed) {
                publish(model, SpeechModelState.Failed(SpeechModelFailure.NETWORK, have, "HTTP $code"))
                return@withContext
            }
            // A server that ignored the range restarts the file; anything already fetched is dropped
            // rather than appended to, which would corrupt it silently.
            if (have > 0 && !resumed) have = 0
            val total = declaredTotal(opened, resumed, have)
            if (total != sizeOf(model)) {
                publish(model, SpeechModelState.Failed(SpeechModelFailure.CORRUPT, have))
                return@withContext
            }
            opened.inputStream.use { stream -> write(model, stream, half, have) }
        } catch (stopped: CancellationException) {
            throw stopped
        } catch (broken: IOException) {
            val cause = broken::class.simpleName.orEmpty() + (broken.message?.let { ": " + it.take(120) } ?: "")
            publish(model, SpeechModelState.Failed(SpeechModelFailure.NETWORK, half.length(), cause))
            return@withContext
        } finally {
            runCatching { connection?.disconnect() }
        }

        finish(model, half, whole)
    }

    /** Checks the finished file and gives it its real name, or says why it could not. */
    private fun finish(model: SpeechModel, half: File, whole: File) {
        if (half.length() != sizeOf(model) || !isGgml(half)) {
            publish(model, SpeechModelState.Failed(SpeechModelFailure.CORRUPT, half.length()))
            return
        }
        runCatching { whole.delete() }
        if (!half.renameTo(whole)) {
            publish(model, SpeechModelState.Failed(SpeechModelFailure.WRITE_FAILED, half.length()))
            return
        }
        publish(model, SpeechModelState.Ready(whole.length()))
    }

    /** Copies the body into [half], starting at [from], reporting as it goes. */
    private suspend fun write(model: SpeechModel, stream: InputStream, half: File, from: Long) {
        val buffer = ByteArray(BLOCK_BYTES)
        var written = from
        var announced = from
        FileOutputStream(half, from > 0).use { out ->
            while (true) {
                currentCoroutineContext().ensureActive()
                val read = stream.read(buffer)
                if (read <= 0) break
                out.write(buffer, 0, read)
                written += read
                if (written - announced >= STEP_BYTES) {
                    announced = written
                    publish(model, SpeechModelState.Downloading(written, sizeOf(model)))
                }
            }
            out.flush()
        }
        publish(model, SpeechModelState.Downloading(written, sizeOf(model)))
    }

    /** The size of the whole file as the server describes it, whichever way it answered. */
    private fun declaredTotal(connection: HttpURLConnection, resumed: Boolean, have: Long): Long {
        val range = connection.getHeaderField("Content-Range")
        if (resumed && range != null) {
            val declared = range.substringAfterLast('/').trim().toLongOrNull()
            if (declared != null) return declared
        }
        val length = connection.getHeaderFieldLong("Content-Length", -1)
        if (length < 0) return -1
        return if (resumed) have + length else length
    }

    /** Whether the file starts with ggml's own magic; anything else is not a model. */
    private fun isGgml(file: File): Boolean = runCatching {
        file.inputStream().use { stream ->
            val head = ByteArray(SpeechModel.MAGIC.size)
            stream.read(head) == head.size && head.contentEquals(SpeechModel.MAGIC)
        }
    }.getOrDefault(false)

    private companion object {
        /** `HttpURLConnection` has no constant for 416; a resume past the end of a file earns it. */
        const val RANGE_NOT_SATISFIABLE = 416

        const val CONNECT_MILLIS = 20_000
        const val READ_MILLIS = 60_000
        const val BLOCK_BYTES = 128 * 1024

        /** How much has to arrive before the progress moves again: often enough to read, rarely enough to be free. */
        const val STEP_BYTES = 512L * 1024

        /** Room left over after the model, so downloading one does not fill the phone exactly. */
        const val HEADROOM_BYTES = 32L * 1024 * 1024
    }
}
