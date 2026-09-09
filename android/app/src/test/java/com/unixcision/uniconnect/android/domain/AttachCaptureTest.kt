package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The capture made at the tap survives as saved state and only ever applies to its own window. */
class AttachCaptureTest {
    private val capture = AttachCapture(AttachRoute.HOST, "m-1", "ws-1", "win-1")

    @Test
    fun aCaptureSurvivesEncodingAndDecoding() {
        assertEquals(capture, AttachCapture.decode(capture.encode()))
        val external = AttachCapture(AttachRoute.EXTERNAL, "m-2", "ws-2", "win-2")
        assertEquals(external, AttachCapture.decode(external.encode()))
    }

    @Test
    fun nothingSavedOrSomethingUnreadableIsNoCapture() {
        assertNull(AttachCapture.decode(null))
        assertNull(AttachCapture.decode(""))
        assertNull(AttachCapture.decode("HOST"))
        assertNull(AttachCapture.decode("PIGEONmwswin"))
        assertNull(AttachCapture.decode("HOSTwswin"))
    }

    @Test
    fun aPickerResultWithoutItsCaptureIsDroppedAndNothingIsSent() {
        // Process died with the picker open and the saved state is gone: the file is not sent anywhere.
        assertEquals(AttachDecision.PickAgain, AttachCapture.resolve(null, "m-1", "ws-1", "win-1", takesFilesNow = true))
        assertEquals(AttachDecision.PickAgain, AttachCapture.resolve("", "m-1", "ws-1", "win-1", takesFilesNow = false))
        assertEquals(AttachDecision.PickAgain, AttachCapture.resolve("garbage", "m-1", "ws-1", "win-1", takesFilesNow = true))
    }

    @Test
    fun aPickerResultForAnotherWindowIsDroppedNotRerouted() {
        val saved = capture.encode()
        assertEquals(AttachDecision.PickAgain, AttachCapture.resolve(saved, "m-1", "ws-1", "win-2", takesFilesNow = true))
        assertEquals(AttachDecision.PickAgain, AttachCapture.resolve(saved, "m-2", "ws-1", "win-1", takesFilesNow = true))
    }

    @Test
    fun aPickerResultWithItsCaptureGoesByTheCapturedRoute() {
        assertEquals(AttachDecision.Send(AttachRoute.HOST), AttachCapture.resolve(capture.encode(), "m-1", "ws-1", "win-1", takesFilesNow = true))
        val external = AttachCapture(AttachRoute.EXTERNAL, "m-1", "ws-1", "win-1").encode()
        assertEquals(AttachDecision.Send(AttachRoute.EXTERNAL), AttachCapture.resolve(external, "m-1", "ws-1", "win-1", takesFilesNow = true))
    }

    @Test
    fun aCapturedHostRouteWithTheCapabilityGoneFailsInsteadOfGoingExternal() {
        assertEquals(AttachDecision.HostLostCapability, AttachCapture.resolve(capture.encode(), "m-1", "ws-1", "win-1", takesFilesNow = false))
    }

    @Test
    fun aCaptureOnlyMatchesItsOwnWindow() {
        assertTrue(capture.matches("m-1", "ws-1", "win-1"))
        assertFalse("another window of the same box", capture.matches("m-1", "ws-1", "win-2"))
        assertFalse("another box", capture.matches("m-1", "ws-2", "win-1"))
        assertFalse("another machine", capture.matches("m-2", "ws-1", "win-1"))
    }
}
