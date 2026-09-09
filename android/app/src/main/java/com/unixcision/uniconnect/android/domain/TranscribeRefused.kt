package com.unixcision.uniconnect.android.domain

/** The machine answered `mobile.audio.transcribe` with an error of the contract. */
class TranscribeRefused(val refusal: TranscribeRefusal, val detail: String? = null) : Exception(detail ?: refusal.name)
