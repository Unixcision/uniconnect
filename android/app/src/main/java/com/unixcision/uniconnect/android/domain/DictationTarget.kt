package com.unixcision.uniconnect.android.domain

/** The window a machine-side transcription belongs to; it travels with every `mobile.audio.transcribe`. */
data class DictationTarget(val machine: Machine, val workspaceID: String, val terminalID: String)
