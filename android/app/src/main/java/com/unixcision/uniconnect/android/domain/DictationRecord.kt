package com.unixcision.uniconnect.android.domain

/**
 * One dictation kept on the phone: its audio from the moment the recording ended, and its text
 * once an engine read it.
 *
 * It exists so nothing said is lost to a transcription that failed or a send that went wrong: the
 * text can be pasted again and the audio played back.
 */
data class DictationRecord(
    val id: String,
    /** When the recording ended, in epoch milliseconds. */
    val createdAt: Long,
    /** The transcription; null while it is being read, or when no engine could read it. */
    val text: String?,
    val state: State,
    /** Absolute path of the kept audio; null once the cleaner removed it (the text stays). */
    val audioPath: String?,
    val audioBytes: Long,
    /** Machine the dictation was meant for; null when it was read on the phone itself. */
    val machineName: String?,
    /** Id of that machine, to send the audio there again; null in entries kept before it was stored. */
    val machineId: String? = null,
) {
    enum class State {
        /** Sent to an engine; nothing came back yet. */
        TRANSCRIBING,

        /** [text] holds what the engine understood. */
        DONE,

        /** No engine read it (failed, cancelled or interrupted): only the audio is left. */
        UNREAD,
    }

    /** Rough length of the recording: the recorder writes AAC at 32 kbit/s. */
    val seconds: Long get() = audioBytes * 8 / 32_000
}
