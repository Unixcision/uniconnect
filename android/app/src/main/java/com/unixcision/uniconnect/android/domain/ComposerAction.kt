package com.unixcision.uniconnect.android.domain

/** What the composer's one floating button does right now. */
enum class ComposerAction {
    /** Send the draft with Enter. */
    SEND,

    /** Start dictating into the empty draft. */
    DICTATE;

    companion object {
        /**
         * The microphone replaces the send button while [draft] holds nothing to send and the
         * reader can dictate.
         *
         * A draft of only spaces or line breaks reads as empty: the keyboard's Enter writes a
         * line break into the draft, so erasing the words can leave one behind, and the button
         * has to come back to the microphone anyway.
         */
        fun decide(draft: String, dictationAvailable: Boolean): ComposerAction =
            if (!hasSomethingToSend(draft) && dictationAvailable) DICTATE else SEND

        /** Whether [draft] carries anything worth sending: blank space alone does not. */
        fun hasSomethingToSend(draft: String): Boolean = draft.isNotBlank()
    }
}
