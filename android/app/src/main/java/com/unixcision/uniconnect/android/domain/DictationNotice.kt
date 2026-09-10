package com.unixcision.uniconnect.android.domain

/**
 * What the composer says when the engine the reader ordered did not run: what happened, and who
 * transcribed in its place.
 *
 * The substitute travels with the notice because a line that only says "no se ha podido" leaves
 * the reader guessing where their voice went. Someone comparing engines needs the answer named,
 * every time it changes under them.
 */
data class DictationNotice(val notice: TranscriptionNotice, val instead: Transcriber?)
