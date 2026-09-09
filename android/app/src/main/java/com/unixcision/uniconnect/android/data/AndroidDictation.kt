package com.unixcision.uniconnect.android.data

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import com.unixcision.uniconnect.android.domain.Dictation
import com.unixcision.uniconnect.android.domain.DictationFailure
import com.unixcision.uniconnect.android.domain.DictationLanguage
import com.unixcision.uniconnect.android.domain.DictationMachine
import com.unixcision.uniconnect.android.domain.DictationState
import kotlinx.coroutines.flow.StateFlow

/**
 * [Dictation] over the platform's own [SpeechRecognizer], with no extra dependency. The on-device
 * recogniser is preferred where the phone has one (Android 12 and later); when it cannot handle
 * the language the network recogniser is tried once instead. Everything touching the recogniser
 * runs on the main thread, which is what it demands; the state machine is the pure
 * [DictationMachine] and is what the screen watches.
 */
class AndroidDictation(private val context: Context) : Dictation {
    private val machine = DictationMachine()
    private val main = Handler(Looper.getMainLooper())
    private var recognizer: SpeechRecognizer? = null
    private var onDevice = false
    private var language = DictationLanguage.DEVICE
    private var triedOnline = false

    override val state: StateFlow<DictationState> get() = machine.state

    override val available: Boolean get() = SpeechRecognizer.isRecognitionAvailable(context)

    override fun start(language: DictationLanguage) {
        main.post {
            this.language = language
            triedOnline = false
            begin(preferOffline = true)
        }
    }

    override fun stop() { main.post { recognizer?.stopListening() } }

    override fun cancel() {
        main.post {
            recognizer?.cancel()
            release()
            machine.cancel()
        }
    }

    override fun reset() { machine.reset() }

    override fun destroy() {
        main.post {
            recognizer?.cancel()
            release()
            if (machine.state.value is DictationState.Listening) machine.cancel()
        }
    }

    private fun begin(preferOffline: Boolean) {
        release()
        if (!available) { machine.fail(DictationFailure.ENGINE_UNAVAILABLE); return }
        val local = preferOffline && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && SpeechRecognizer.isOnDeviceRecognitionAvailable(context)
        val created = runCatching {
            if (local) SpeechRecognizer.createOnDeviceSpeechRecognizer(context) else SpeechRecognizer.createSpeechRecognizer(context)
        }.getOrNull()
        if (created == null) { machine.fail(DictationFailure.ENGINE_UNAVAILABLE); return }
        onDevice = local
        // The listener goes in before listening starts, or early callbacks are lost.
        created.setRecognitionListener(listener)
        recognizer = created
        machine.onStarting()
        created.startListening(intent(local))
    }

    private fun intent(local: Boolean) = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
        putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
        putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
        putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, context.packageName)
        language.tag?.let { putExtra(RecognizerIntent.EXTRA_LANGUAGE, it) }
        if (local) putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
    }

    private val listener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {}
        override fun onBeginningOfSpeech() {}
        override fun onRmsChanged(rmsdB: Float) { machine.onLevel(rmsdB) }
        override fun onBufferReceived(buffer: ByteArray?) {}
        override fun onEndOfSpeech() {}
        override fun onEvent(eventType: Int, params: Bundle?) {}

        override fun onPartialResults(partialResults: Bundle?) {
            partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()?.let { machine.onPartial(it) }
        }

        override fun onResults(results: Bundle?) {
            main.post { release() }
            machine.onFinal(results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull())
        }

        override fun onError(error: Int) {
            // The local engine has no model for the language: try the network one once.
            if (onDevice && !triedOnline && error in LANGUAGE_ERRORS) {
                triedOnline = true
                main.post { begin(preferOffline = false) }
                return
            }
            main.post { release() }
            machine.onError(failureOf(error))
        }
    }

    private fun release() {
        recognizer?.let { runCatching { it.destroy() } }
        recognizer = null
    }

    companion object {
        /** ERROR_LANGUAGE_NOT_SUPPORTED, ERROR_LANGUAGE_UNAVAILABLE and ERROR_CANNOT_CHECK_SUPPORT (Android 13), as numbers so older phones link. */
        private val LANGUAGE_ERRORS = setOf(12, 13, 14)

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
