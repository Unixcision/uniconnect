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

        /**
         * Whether the box offers a microphone of its own to dictate more into [draft]: while the
         * floating button sends, a dictation, typed text or both can keep growing the same message,
         * as a chat does, instead of having to send to dictate again.
         */
        fun dictatesMore(draft: String, dictationAvailable: Boolean): Boolean = dictationAvailable && hasSomethingToSend(draft)
    }
}
