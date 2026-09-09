package com.unixcision.uniconnect.android.domain

/** What the composer's one floating button does right now. */
enum class ComposerAction {
    /** Send the draft with Enter. */
    SEND,

    /** Start dictating into the empty draft. */
    DICTATE;

    companion object {
        /** The microphone only replaces the send button while there is nothing to send and the phone can recognise speech. */
        fun decide(draftEmpty: Boolean, dictationAvailable: Boolean): ComposerAction =
            if (draftEmpty && dictationAvailable) DICTATE else SEND
    }
}
