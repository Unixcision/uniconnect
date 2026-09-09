package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.AudioPayload
import com.unixcision.uniconnect.android.domain.DictationTarget
import com.unixcision.uniconnect.android.domain.HostTranscription
import com.unixcision.uniconnect.android.domain.MachineFailure
import com.unixcision.uniconnect.android.domain.TranscribeRefusal
import com.unixcision.uniconnect.android.domain.TranscribeRefused
import com.unixcision.uniconnect.android.domain.Transcript
import org.json.JSONObject

/**
 * `transcribe.v1` over the framed RPC session the app already speaks: one connection, one call,
 * the whole recording as base64 inside the request. The machine may take as long as a model needs,
 * so the deadline is a minute and a half; anything the contract refuses comes back as
 * [TranscribeRefused] and anything the connection refuses as [MachineFailure].
 *
 * The request is measured before it is written. A frame the transport would refuse never leaves
 * the phone: it is refused here as `too_large`, which is what the reader is told, instead of
 * breaking a connection the machine could not have answered on.
 */
class NativeHostTranscription(private val rpc: FramedRpcClient) : HostTranscription {
    override suspend fun transcribe(target: DictationTarget, audio: ByteArray, mime: String, language: String?): Transcript =
        rpc.open(target.machine.endpoint).use { session -> over(session, target, audio, mime, language) }

    /** The one call on an open session, which is what the tests drive against a socket pair. */
    internal suspend fun over(session: FramedRpcSession, target: DictationTarget, audio: ByteArray, mime: String, language: String?): Transcript {
        if (!AudioPayload.fits(audio.size.toLong())) throw TranscribeRefused(TranscribeRefusal.TOO_LARGE)
        val encoded = AudioPayload.encode(audio)
        val fields = (target.workspaceID + target.terminalID + mime + language.orEmpty()).toByteArray(Charsets.UTF_8).size
        if (!AudioPayload.requestFits(encoded.length.toLong(), fields.toLong())) throw TranscribeRefused(TranscribeRefusal.TOO_LARGE)
        val params = JSONObject()
            .put("audio", encoded)
            .put("mime", mime)
            .put("workspace_id", target.workspaceID)
            .put("terminal_id", target.terminalID)
        language?.let { params.put("language", it) }
        val result = try {
            session.call(METHOD, params, DEADLINE_MILLIS).value.getJSONObject("result")
        } catch (refused: MachineFailure.Rejected) {
            throw TranscribeRefused(TranscribeRefusal.of(refused.code), refused.detail)
        }
        return Transcript(
            text = result.optString("text"),
            engine = result.optString("engine"),
            seconds = result.optDouble("seconds", 0.0),
            tookMillis = result.optLong("took_ms", 0),
        )
    }

    private companion object {
        const val METHOD = "mobile.audio.transcribe"

        /** Whisper on the machine reads five minutes of audio in far less, but never in twelve seconds. */
        const val DEADLINE_MILLIS = 90_000L
    }
}
