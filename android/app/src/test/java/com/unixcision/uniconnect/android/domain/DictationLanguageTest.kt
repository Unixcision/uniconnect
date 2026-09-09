package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** What each language means to the phone's recogniser and to a machine that transcribes. */
class DictationLanguageTest {
    @Test
    fun theDeviceLanguageIsNamedInsteadOfLeftOut() {
        assertEquals("es-ES", DictationLanguage.DEVICE.recognitionTag("es-ES"))
        assertEquals("some engines fall back to English when asked for nothing", "en-GB", DictationLanguage.DEVICE.recognitionTag("en-GB"))
    }

    @Test
    fun aChosenLanguageWinsOverTheDeviceOne() {
        assertEquals("es-ES", DictationLanguage.ES_ES.recognitionTag("ja-JP"))
        assertEquals("en-US", DictationLanguage.EN_US.recognitionTag("ja-JP"))
    }

    @Test
    fun anEmptyTagIsNeverSent() {
        assertNull(DictationLanguage.DEVICE.recognitionTag(""))
        assertNull(DictationLanguage.DEVICE.recognitionTag("   "))
    }

    @Test
    fun theMachineTakesTheTwoLetterCodeOrDecidesForItself() {
        assertEquals("es", DictationLanguage.ES_ES.code)
        assertEquals("en", DictationLanguage.EN_US.code)
        assertNull(DictationLanguage.DEVICE.code)
    }
}
