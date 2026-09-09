package com.unixcision.uniconnect.android.domain

/**
 * What `mobile.audio.transcribe` answers: the [text] the machine understood, the [engine] that
 * produced it (`whisper.cpp`, for instance), the [seconds] of audio it read and how long it
 * [tookMillis]. Only [text] reaches the composer; the rest is there to be logged and compared.
 */
data class Transcript(val text: String, val engine: String = "", val seconds: Double = 0.0, val tookMillis: Long = 0)
