package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.AudioClip
import com.unixcision.uniconnect.android.domain.AudioDecoder
import com.unixcision.uniconnect.android.domain.LocalTranscription
import com.unixcision.uniconnect.android.domain.LocalTranscriptionFailed
import com.unixcision.uniconnect.android.domain.PhoneTranscriber
import com.unixcision.uniconnect.android.domain.SpeechModelStore

/**
 * [PhoneTranscriber] with the same pieces the live dictation on the phone uses: the platform
 * decoder turns the kept AAC into samples and Whisper reads them with the downloaded model.
 */
class WhisperPhoneTranscriber(
    private val decoder: AudioDecoder,
    private val engine: LocalTranscription,
    private val models: SpeechModelStore,
) : PhoneTranscriber {
    override val ready: Boolean get() = engine.available && models.ready != null

    override suspend fun transcribe(audio: ByteArray, language: String?): String {
        val model = models.ready ?: throw LocalTranscriptionFailed("no model downloaded")
        val path = models.path(model) ?: throw LocalTranscriptionFailed("the model file is missing")
        val samples = decoder.decode(KeptAudio(audio))
        return engine.transcribe(samples, path, language, null)?.text ?: throw LocalTranscriptionFailed("cancelled")
    }

    /** The kept recording, read only: the history owns the file and nothing here deletes it. */
    private class KeptAudio(private val content: ByteArray) : AudioClip {
        override val bytes: Long get() = content.size.toLong()
        override fun read(): ByteArray = content
        override fun delete() {}
    }
}
