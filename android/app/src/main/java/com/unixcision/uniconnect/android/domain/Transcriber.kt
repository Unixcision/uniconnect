package com.unixcision.uniconnect.android.domain

/**
 * Who is turning the current recording into text, as the dictation bar says it.
 *
 * The machine of the open window is missing on purpose: when the terminal you are looking at is
 * the one transcribing, saying so is noise. Everything else is worth a line, because the reader
 * would otherwise have no way of knowing their voice went to another machine, to a model on this
 * phone, or to the system recogniser that understands least.
 */
sealed interface Transcriber {
    /** A machine that is not the one the open window lives on. */
    data class OtherMachine(val name: String) : Transcriber

    /** Whisper running here, with no connection. */
    data object PhoneWhisper : Transcriber

    /** The phone's own system recogniser. */
    data object PhoneRecogniser : Transcriber
}
