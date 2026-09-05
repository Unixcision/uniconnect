package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.MachineFailure
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.lang.reflect.InvocationTargetException

class ColdTerminalReplayTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
    private val client = NativeMachineClient(FramedRpcClient(scope))
    private val surfaceID = "00000000-0000-4000-8000-000000000042"
    private val decode = NativeMachineClient::class.java.getDeclaredMethod("decodeReplay", JSONObject::class.java, String::class.java).apply { isAccessible = true }

    @After fun closeScope() { scope.cancel() }

    @Test fun notReadyReplayWaitsForTheSubscribedScreenInsteadOfDeclaringIncompatibility() {
        // This invokes the existing replay classifier, without weakening the tailnet transport for tests.
        val response = JSONObject().put("surface_id", surfaceID).put("seq", 0).put("is_ready", false)
        assertNull(decode.invoke(client, response, surfaceID))
    }

    @Test fun readyReplyWithoutACompatibleScreenStillFailsExplicitly() {
        val response = JSONObject().put("surface_id", surfaceID).put("is_ready", true)
        val failure = assertThrows(InvocationTargetException::class.java) { decode.invoke(client, response, surfaceID) }
        assertTrue(failure.cause is MachineFailure.UnsupportedTerminal)
    }

    @Test fun pendingReplyForAnotherSurfaceCannotBeAccepted() {
        val response = JSONObject().put("surface_id", "00000000-0000-4000-8000-000000000043").put("is_ready", false)
        val failure = assertThrows(InvocationTargetException::class.java) { decode.invoke(client, response, surfaceID) }
        assertTrue(failure.cause is IllegalArgumentException)
    }
}
