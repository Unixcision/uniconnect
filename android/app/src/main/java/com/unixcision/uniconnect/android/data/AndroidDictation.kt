package com.unixcision.uniconnect.android.data

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import com.unixcision.uniconnect.android.domain.Dictation
import com.unixcision.uniconnect.android.domain.DictationAttempts
import com.unixcision.uniconnect.android.domain.DictationFailure
import com.unixcision.uniconnect.android.domain.DictationLanguage
import com.unixcision.uniconnect.android.domain.DictationMachine
import com.unixcision.uniconnect.android.domain.DictationState
import com.unixcision.uniconnect.android.domain.RecogniserRecovery
import java.util.Locale
import kotlinx.coroutines.flow.StateFlow

/**
 * [Dictation] over the platform's own [SpeechRecognizer], with no extra dependency. The on-device
 * recogniser is preferred where the phone has one (Android 12 and later); an engine that gives up
 * before a word could have been said is not taken at its word, and the network recogniser is tried
 * once instead. Everything touching the recogniser runs on the main thread, which is what it
 * demands; the state machine is the pure [DictationMachine] and is what the screen watches.
 *
 * The bar is on screen from the moment the microphone is tapped, and a retry keeps it there: the
 * reader sees a dictation that is starting, never a button that seems to do nothing.
 *
 * Every try carries a number from [DictationAttempts], so a cancel between an engine's failure and
 * the retry queued for it leaves that retry with nothing to do: the microphone never reopens on its
 * own, and a late result never lands in a dictation the reader already left.
 */
class AndroidDictation(private val context: Context) : Dictation {
    private val machine = DictationMachine()
    private val main = Handler(Looper.getMainLooper())
    private var recognizer: SpeechRecognizer? = null
    private var onDevice = false
    private var language = DictationLanguage.DEVICE
    private var triedOnline = false
    private var startedAt = 0L
    private val attempts = DictationAttempts()

    override val state: StateFlow<DictationState> get() = machine.state

    override val available: Boolean get() = SpeechRecognizer.isRecognitionAvailable(context)

    override fun start(language: DictationLanguage) {
        main.post {
            this.language = language
            triedOnline = false
            // The bar belongs to the reader from the tap, not from the engine's first callback.
            machine.onStarting()
            begin(attempts.begin(), preferOffline = true)
        }
    }

    override fun stop() { main.post { recognizer?.stopListening() } }

    override fun cancel() {
        main.post {
            // Whatever is in flight stops speaking for this dictation before anything else happens.
            attempts.abandon()
            recognizer?.cancel()
            release()
            machine.cancel()
        }
    }

    override fun reset() { machine.reset() }

    override fun destroy() {
        main.post {
            attempts.abandon()
            recognizer?.cancel()
            release()
            if (machine.state.value is DictationState.Listening) machine.cancel()
        }
    }

    private fun begin(attempt: Int, preferOffline: Boolean) {
        // The reader cancelled, or started again, while this try was waiting its turn.
        if (!attempts.isLive(attempt)) return
        release()
        if (!available) { machine.fail(DictationFailure.ENGINE_UNAVAILABLE); return }
        val local = preferOffline && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && SpeechRecognizer.isOnDeviceRecognitionAvailable(context)
        val created = runCatching {
            if (local) SpeechRecognizer.createOnDeviceSpeechRecognizer(context) else SpeechRecognizer.createSpeechRecognizer(context)
        }.getOrNull()
        if (created == null) { machine.fail(DictationFailure.ENGINE_UNAVAILABLE); return }
        onDevice = local
        // The listener goes in before listening starts, or early callbacks are lost.
        created.setRecognitionListener(Callbacks(attempt))
        recognizer = created
        if (machine.state.value !is DictationState.Listening) machine.onStarting()
        startedAt = SystemClock.elapsedRealtime()
        created.startListening(intent(local))
    }

    private fun intent(local: Boolean) = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
        putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
        putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
        putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, context.packageName)
        // Silence at the start is someone thinking, not someone who has finished.
        putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, SILENCE_MILLIS)
        putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, SILENCE_MILLIS)
        putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_MINIMUM_LENGTH_MILLIS, MINIMUM_MILLIS)
        language.recognitionTag(Locale.getDefault().toLanguageTag())?.let { putExtra(RecognizerIntent.EXTRA_LANGUAGE, it) }
        if (local) putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
    }

    /** One try's callbacks; they do nothing once that try has been left behind. */
    private inner class Callbacks(private val attempt: Int) : RecognitionListener {
        private val live: Boolean get() = attempts.isLive(attempt)

        override fun onReadyForSpeech(params: Bundle?) {}
        override fun onBeginningOfSpeech() {}
        override fun onRmsChanged(rmsdB: Float) { if (live) machine.onLevel(rmsdB) }
        override fun onBufferReceived(buffer: ByteArray?) {}
        override fun onEndOfSpeech() {}
        override fun onEvent(eventType: Int, params: Bundle?) {}

        override fun onPartialResults(partialResults: Bundle?) {
            if (!live) return
            partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()?.let { machine.onPartial(it) }
        }

        override fun onResults(results: Bundle?) {
            if (!live) return
            main.post { release() }
            machine.onFinal(results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull())
        }

        override fun onError(error: Int) {
            if (!live) return
            val failure = failureOf(error)
            val elapsed = SystemClock.elapsedRealtime() - startedAt
            val heard = (machine.state.value as? DictationState.Listening)?.partial?.isNotBlank() == true
            // An engine that gives up before a word could have been said is not answering about
            // what was said, so the network recogniser gets the same dictation without a word to
            // the reader, and the bar stays where it is.
            if (RecogniserRecovery.retryOnline(onDevice, triedOnline, heard, elapsed, failure)) {
                triedOnline = true
                main.post { begin(attempt, preferOffline = false) }
                return
            }
            main.post { release() }
            if (RecogniserRecovery.silent(heard, elapsed, failure)) machine.fail(DictationFailure.RECOGNISER_SILENT)
            else machine.onError(failure)
        }
    }

    private fun release() {
        recognizer?.let { runCatching { it.destroy() } }
        recognizer = null
    }

    companion object {
        /** How long a silence may last before the engine decides the sentence is over. */
        private const val SILENCE_MILLIS = 1_500

        /** The engine waits at least this long before it may end on its own. */
        private const val MINIMUM_MILLIS = 2_000

        /** The platform's error code in the reader's terms. */
        fun failureOf(code: Int): DictationFailure = when (code) {
            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> DictationFailure.NO_PERMISSION
            SpeechRecognizer.ERROR_NETWORK, SpeechRecognizer.ERROR_NETWORK_TIMEOUT, SpeechRecognizer.ERROR_SERVER, 11 -> DictationFailure.NO_NETWORK
            SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> DictationFailure.NOT_UNDERSTOOD
            SpeechRecognizer.ERROR_RECOGNIZER_BUSY, 10 -> DictationFailure.BUSY
            12, 13, 14 -> DictationFailure.ENGINE_UNAVAILABLE
            else -> DictationFailure.OTHER
        }
    }
}
