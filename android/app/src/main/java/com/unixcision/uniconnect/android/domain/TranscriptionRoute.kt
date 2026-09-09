package com.unixcision.uniconnect.android.domain

/**
 * Which engine a dictation uses and what the reader is told about it. Pure: the decision depends
 * only on the setting, on whether the machine announces `transcribe.v1` and on whether the phone
 * has a recogniser at all, so it is decided the same way from any entry point and tested without
 * a microphone or a socket.
 */
data class TranscriptionRoute(val engine: TranscriptionEngine, val notice: TranscriptionNotice? = null) {
    companion object {
        /** The engine for [mode] against a machine that [hostTranscribes] or not. */
        fun decide(mode: TranscriptionMode, hostTranscribes: Boolean, phoneAvailable: Boolean = true): TranscriptionRoute = when (mode) {
            TranscriptionMode.PHONE -> TranscriptionRoute(TranscriptionEngine.PHONE)
            TranscriptionMode.AUTO ->
                if (hostTranscribes) TranscriptionRoute(TranscriptionEngine.HOST)
                else TranscriptionRoute(TranscriptionEngine.PHONE, TranscriptionNotice.HOST_CANNOT.takeIf { phoneAvailable })
            TranscriptionMode.HOST ->
                if (hostTranscribes) TranscriptionRoute(TranscriptionEngine.HOST)
                else TranscriptionRoute(TranscriptionEngine.PHONE, TranscriptionNotice.HOST_REQUIRED_UNAVAILABLE)
        }

        /** Whether a microphone is worth offering at all: one of the two engines has to be able to run. */
        fun canDictate(mode: TranscriptionMode, hostTranscribes: Boolean, phoneAvailable: Boolean): Boolean =
            if (mode == TranscriptionMode.PHONE) phoneAvailable else hostTranscribes || phoneAvailable
    }
}
