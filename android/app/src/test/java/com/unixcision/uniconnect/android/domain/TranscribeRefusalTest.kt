package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Test

/** Every error code of `transcribe.v1` as the app names it; an unknown code is never guessed. */
class TranscribeRefusalTest {
    @Test
    fun everyCodeOfTheContractIsRecognised() {
        assertEquals(TranscribeRefusal.TOO_LARGE, TranscribeRefusal.of("too_large"))
        assertEquals(TranscribeRefusal.UNSUPPORTED, TranscribeRefusal.of("unsupported"))
        assertEquals(TranscribeRefusal.LOCKED, TranscribeRefusal.of("locked"))
        assertEquals(TranscribeRefusal.INVALID_PARAMS, TranscribeRefusal.of("invalid_params"))
        assertEquals(TranscribeRefusal.IO_FAILED, TranscribeRefusal.of("io_failed"))
    }

    @Test
    fun spacingAndCaseFromAHostDoNotChangeTheMeaning() {
        assertEquals(TranscribeRefusal.LOCKED, TranscribeRefusal.of(" LOCKED "))
        assertEquals(TranscribeRefusal.TOO_LARGE, TranscribeRefusal.of("Too_Large"))
    }

    @Test
    fun anythingElseStaysUnknown() {
        assertEquals(TranscribeRefusal.UNKNOWN, TranscribeRefusal.of(null))
        assertEquals(TranscribeRefusal.UNKNOWN, TranscribeRefusal.of(""))
        assertEquals(TranscribeRefusal.UNKNOWN, TranscribeRefusal.of("model_cold"))
    }
}
