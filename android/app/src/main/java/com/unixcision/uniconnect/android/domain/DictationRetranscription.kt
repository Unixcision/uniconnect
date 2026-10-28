package com.unixcision.uniconnect.android.domain

/**
 * «Volver a transcribir»: sends a dictation's kept audio to a machine again and stores the new text
 * in place of the old one.
 *
 * For the transcription that came back short or broken (only the end of a long recording), or a
 * recording no engine could read at the time. The audio never leaves the history: only a copy of
 * its bytes travels.
 */
class DictationRetranscription(
    private val history: DictationHistory,
    private val transcription: HostTranscription,
    /** Reads the kept audio at a path; null when it is gone. */
    private val readAudio: (String) -> ByteArray?,
) {
    /** The new text, already stored in the history. */
    suspend fun run(record: DictationRecord, machine: Machine, language: String?): String = run(record, listOf(machine), language)

    /** The new text from the first of [machines], already stored in the history. */
    suspend fun run(record: DictationRecord, machines: List<Machine>, language: String?): String {
        val path = record.audioPath ?: throw MissingAudio()
        val audio = readAudio(path) ?: throw MissingAudio()
        val machine = machines.firstOrNull() ?: throw NoMachine()
        val transcript = transcription.transcribe(DictationTarget(machine), audio, MIME, language)
        history.replaceText(record.id, transcript.text)
        return transcript.text
    }

    /** The audio of this dictation was cleaned up, so there is nothing to send. */
    class MissingAudio : Exception("the kept audio is gone")

    /** No saved machine to send it to. */
    class NoMachine : Exception("no saved machine")

    companion object {
        /** What the recorder writes and what the contract names for it. */
        const val MIME = "audio/mp4"

        /**
         * The machine to send it to: the one it was dictated for (by id, or by name for entries
         * kept before the id was stored), otherwise the first saved one.
         */
        fun machineFor(record: DictationRecord, machines: List<Machine>): Machine? =
            machines.firstOrNull { it.id == record.machineId }
                ?: machines.firstOrNull { it.name == record.machineName }
                ?: machines.firstOrNull()

        /** The machines to try, in order. */
        fun machinesFor(record: DictationRecord, machines: List<Machine>, preferredID: String?): List<Machine> =
            listOfNotNull(machineFor(record, machines))
    }
}
