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

    /**
     * The new text from the first of [machines] that reads it, already stored in the history.
     *
     * A machine with no engine (it answers `unsupported`) or one that does not answer passes the
     * audio to the next, as a dictation does; any other refusal is the answer and is thrown.
     *
     * - Throws: [MissingAudio] without the kept audio, [NoMachine] with no machine to try, and
     *   the last machine's failure when none could read it.
     */
    suspend fun run(record: DictationRecord, machines: List<Machine>, language: String?): String {
        val path = record.audioPath ?: throw MissingAudio()
        val audio = readAudio(path) ?: throw MissingAudio()
        if (machines.isEmpty()) throw NoMachine()
        var last: Exception? = null
        for (machine in machines) {
            val transcript = try {
                transcription.transcribe(DictationTarget(machine), audio, MIME, language)
            } catch (failure: TranscribeRefused) {
                if (failure.refusal != TranscribeRefusal.UNSUPPORTED) throw failure
                last = failure
                continue
            } catch (failure: MachineFailure) {
                last = failure
                continue
            }
            history.replaceText(record.id, transcript.text)
            return transcript.text
        }
        throw last ?: NoMachine()
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

        /**
         * The machines to try, in order: the transcriber the reader picked, the one it was
         * dictated for, then every other saved machine.
         *
         * - Parameter preferredID: the machine chosen under «Un equipo concreto», or null.
         */
        fun machinesFor(record: DictationRecord, machines: List<Machine>, preferredID: String?): List<Machine> {
            val preferred = machines.firstOrNull { it.id == preferredID }
            return (listOfNotNull(preferred, machineFor(record, machines)) + machines).distinct()
        }
    }
}
