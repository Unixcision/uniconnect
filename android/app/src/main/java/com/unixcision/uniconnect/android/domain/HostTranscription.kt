package com.unixcision.uniconnect.android.domain

/** `transcribe.v1`: one recording travels to the machine and comes back as text. */
interface HostTranscription {
    /**
     * Sends [audio] of type [mime] recorded for [target] and returns what the machine understood.
     *
     * - Parameter language: the two-letter code the machine should assume, or null to let it decide.
     * - Throws: [TranscribeRefused] when the machine answers an error of the contract, and
     *   [MachineFailure] when the connection itself fails.
     */
    suspend fun transcribe(target: DictationTarget, audio: ByteArray, mime: String, language: String?): Transcript
}
