package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.Machine
import com.unixcision.uniconnect.android.domain.MachineEndpoint
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `box-close.v1` on the wire, checked against the contract's own examples: the same files the Mac
 * and Linux tests read, so a change on either side breaks here instead of on the day a close from
 * the phone does nothing.
 */
class BoxCloseContractTest {
    private val client = NativeMachineClient(FramedRpcClient(CoroutineScope(Dispatchers.Unconfined)))
    private val mac = Machine("mac", "MacBook de Daniel", MachineEndpoint.parse("100.64.0.1", "8855")!!)

    private fun fixture(name: String): JSONObject = JSONObject(
        requireNotNull(javaClass.classLoader?.getResourceAsStream("box-close-v1/$name"))
            { "falta el fixture del contrato: contracts/box-close-v1/$name" }
            .bufferedReader().readText()
    )

    @Test fun closingAWindowSendsTerminalCloseWithBothIdsAndNothingElse() {
        val agreed = fixture("close-terminal-request.json")
        val (method, params) = client.closeRequest(agreed.getString("workspace_id"), agreed.getString("terminal_id"))
        assertEquals("terminal.close", method)
        assertEquals(agreed.keys().asSequence().toSet(), params.keys().asSequence().toSet())
        assertEquals(agreed.getString("workspace_id"), params.getString("workspace_id"))
        assertEquals(agreed.getString("terminal_id"), params.getString("terminal_id"))
    }

    @Test fun closingAWorkspaceSendsWorkspaceCloseWithOnlyItsId() {
        val (method, params) = client.closeRequest("55C41385-9DB8-4451-9988-6898B567A658", terminalID = null)
        assertEquals("workspace.close", method)
        assertEquals(setOf("workspace_id"), params.keys().asSequence().toSet())
        assertEquals("55C41385-9DB8-4451-9988-6898B567A658", params.getString("workspace_id"))
    }

    @Test(expected = IllegalArgumentException::class)
    fun aBlankIdNeverTravels() {
        client.closeRequest("w", terminalID = "")
    }

    @Test fun theAnswerIsTheWholeListDrawnAsItComes() {
        val response = fixture("close-terminal-response.json")
        val snapshot = client.decodeClosed(mac, response, "closed_terminal_id", response.getString("closed_terminal_id"))
        assertTrue(snapshot.closesBoxes)
        assertEquals("MacBook de Daniel", snapshot.serverName)
        assertEquals(listOf("PROYECTOS"), snapshot.workspaces.map { it.name })
        assertTrue(snapshot.workspaces.single().windows.isEmpty())
        // The Mac sends its UUIDs in capitals; the id it names is still the one asked for.
        client.decodeClosed(mac, response, "closed_terminal_id", response.getString("closed_terminal_id").lowercase())
    }

    @Test(expected = IllegalArgumentException::class)
    fun anAnswerAboutAnotherWindowIsNotTakenAsThisOne() {
        client.decodeClosed(mac, fixture("close-terminal-response.json"), "closed_terminal_id", "OTRA-VENTANA")
    }

    @Test fun aWindowThatWasAlreadyGoneComesBackAsNotFoundWithTheHostsWords() {
        val rejected = FramedRpcSession.rejection(fixture("close-error-not-found.json"))
        assertEquals("not_found", rejected.code)
        assertEquals("Esa ventana ya no existe en el equipo.", rejected.detail)
        assertNull(rejected.failureCause)
        assertNull(rejected.createdTerminalID)
    }

    @Test fun withoutTheCapabilityNothingOffersToClose() {
        val response = fixture("close-terminal-response.json").put("capabilities", org.json.JSONArray().put("box_update"))
        assertFalse(client.decodeClosed(mac, response, "closed_terminal_id", response.getString("closed_terminal_id")).closesBoxes)
    }
}
