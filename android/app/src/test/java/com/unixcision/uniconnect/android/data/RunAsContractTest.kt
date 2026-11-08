package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.ResourceCreation
import com.unixcision.uniconnect.android.domain.RunAs
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** `run-as.v1` as the phone sends it, compared with the contract's own requests. */
class RunAsContractTest {
    private val client = NativeMachineClient(FramedRpcClient(CoroutineScope(Dispatchers.Unconfined)))

    private fun fixture(name: String): JSONObject = JSONObject(
        requireNotNull(javaClass.classLoader?.getResourceAsStream("run-as-v1/$name"))
            { "falta el fixture del contrato: contracts/run-as-v1/$name" }
            .bufferedReader().readText()
    )

    /** Same keys and same values, nested objects included: the shape of the wire, not only its fields. */
    private fun assertSameJson(expected: JSONObject, actual: JSONObject) {
        assertEquals(expected.keys().asSequence().toSet(), actual.keys().asSequence().toSet())
        for (key in expected.keys()) {
            val wanted = expected.get(key)
            if (wanted is JSONObject) assertSameJson(wanted, actual.getJSONObject(key)) else assertEquals("«$key»", wanted, actual.get(key))
        }
    }

    @Test fun claudeAsRootWithSudoTravelsAsTheContractWritesIt() {
        val agreed = fixture("create-root-sandbox.json")
        val switch = agreed.getJSONObject("run_as")
        val request = ResourceCreation.Terminal(
            agreed.getString("workspace_id"), agreed.getString("name"), null, null, agreed.getString("agent"),
            runAs = RunAs(RunAs.Mode.ROOT, RunAs.Method.SUDO, password = switch.getString("password")), isSandbox = true,
        )
        assertSameJson(agreed, client.creationParameters(request))
    }

    @Test fun anotherUserWithSuTravelsWithItsNameAndASandboxFlagOfFalse() {
        val agreed = fixture("create-user-su.json")
        val switch = agreed.getJSONObject("run_as")
        val request = ResourceCreation.Terminal(
            agreed.getString("workspace_id"), agreed.getString("name"), null, null, agreed.getString("agent"),
            runAs = RunAs(RunAs.Mode.USER, RunAs.Method.SU, switch.getString("user"), switch.getString("password")), isSandbox = false,
        )
        assertSameJson(agreed, client.creationParameters(request))
    }

    @Test fun claudeAsRootGoesWithIsSandboxEvenIfTheBoxWasClearedSomehow() {
        val request = ResourceCreation.Terminal("w", "CLAUDE ROOT", null, null, "claude", runAs = RunAs(RunAs.Mode.ROOT), isSandbox = false)
        assertTrue(client.creationParameters(request).getBoolean("is_sandbox"))
        // Codex as root keeps what the reader chose.
        assertFalse(client.creationParameters(request.copy(agentID = "codex")).getBoolean("is_sandbox"))
    }

    @Test fun theConnectedUserTravelsAsBeforeTheContract() {
        val plain = client.creationParameters(ResourceCreation.Terminal("w", "APP", null, null, "claude", runAs = RunAs(RunAs.Mode.CURRENT)))
        assertEquals(setOf("name", "workspace_id", "agent"), plain.keys().asSequence().toSet())
        // IS_SANDBOX alone, for an AI that stays with the connected user.
        val sandboxed = client.creationParameters(ResourceCreation.Terminal("w", "APP", null, null, "claude", isSandbox = true))
        assertEquals(setOf("name", "workspace_id", "agent", "is_sandbox"), sandboxed.keys().asSequence().toSet())
        assertTrue(sandboxed.getBoolean("is_sandbox"))
    }

    @Test fun aPasswordNotTypedDoesNotTravelAtAll() {
        val noPassword = client.creationParameters(
            ResourceCreation.Terminal("w", "ROOT", null, null, "claude", runAs = RunAs(RunAs.Mode.ROOT, password = ""), isSandbox = true)
        ).getJSONObject("run_as")
        assertEquals(setOf("mode", "method"), noPassword.keys().asSequence().toSet())
    }

    @Test fun aPasswordTravelsAsTypedSpacesIncluded() {
        val typed = " clave con espacios "
        val switch = client.creationParameters(
            ResourceCreation.Terminal("w", "ROOT", null, null, "claude", runAs = RunAs(RunAs.Mode.ROOT, RunAs.Method.SU, password = typed))
        ).getJSONObject("run_as")
        assertEquals(typed, switch.getString("password"))
        assertEquals("su", switch.getString("method"))
    }

    @Test fun theFirstWindowOfANewBoxTakesTheSwitchOnlyWhenTheHostOpensIt() {
        val switch = RunAs(RunAs.Mode.ROOT, password = "x")
        val withWindow = client.creationParameters(ResourceCreation.Workspace("Proyecto", "/home/dani", null, runAs = switch, isSandbox = true))
        assertEquals("root", withWindow.getJSONObject("run_as").getString("mode"))
        assertTrue(withWindow.getBoolean("is_sandbox"))
        val empty = client.creationParameters(ResourceCreation.Workspace("Proyecto", "/home/dani", null, initialTerminal = false, runAs = switch, isSandbox = true))
        assertFalse(empty.has("run_as"))
        assertFalse(empty.has("is_sandbox"))
    }

    @Test fun aFailedSwitchSaysWhyAndWhichWindowWasCreated() {
        val flat = FramedRpcSession.rejection(JSONObject(
            """{"code":"run_as_failed","message":"La contraseña no es correcta. La ventana se ha creado sin IA.","cause":"password_incorrect","created_terminal_id":"E3A54AE6"}"""
        ))
        assertEquals("run_as_failed", flat.code)
        assertEquals("password_incorrect", flat.failureCause)
        assertEquals("E3A54AE6", flat.createdTerminalID)
        // The Mac's error helper puts extra fields under `data`; the phone reads them there too.
        val nested = FramedRpcSession.rejection(JSONObject(
            """{"code":"run_as_failed","message":"…","data":{"cause":"timeout","created_terminal_id":"W2"}}"""
        ))
        assertEquals("timeout", nested.failureCause)
        assertEquals("W2", nested.createdTerminalID)
        // A JSON null is no id: Android's optString would read it as the text "null".
        val none = FramedRpcSession.rejection(JSONObject("""{"code":"run_as_failed","message":"…","cause":null,"created_terminal_id":null}"""))
        assertNull(none.failureCause)
        assertNull(none.createdTerminalID)
    }
}
