package com.unixcision.uniconnect.android.domain

import com.unixcision.uniconnect.android.domain.MachineDraft.Problem
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The rules the machine form applies, shared by adding a machine and by correcting one. */
class MachineDraftTest {
    private fun machine(id: String, name: String, host: String, port: Int = 58465) =
        Machine(id, name, requireNotNull(MachineEndpoint.parse(host, port.toString())))

    private val minipc = machine("minipc", "MINIPC Linux", "100.123.234.20")
    private val mac = machine("mac", "MacBook de Daniel", "100.120.128.58")
    private val stored = listOf(minipc, mac)

    private fun draft(name: String = "Portatil", address: String = "100.99.1.2", port: String = "58465") =
        MachineDraft(name, address, port)

    @Test
    fun aWellFormedDraftHasNoProblem() {
        assertNull(draft().problem(stored))
        assertEquals(MachineEndpoint.parse("100.99.1.2", "58465"), draft().endpoint)
    }

    @Test
    fun theNameMustBeUsable() {
        assertEquals(Problem.NAME, draft(name = "   ").problem(stored))
        assertEquals(Problem.NAME, draft(name = "a".repeat(81)).problem(stored))
        // Surrounding blanks are typing, not a mistake: they are trimmed rather than rejected.
        assertNull(draft(name = "  Portatil  ").problem(stored))
        assertEquals("Portatil", draft(name = "  Portatil  ").machine("id").name)
    }

    @Test
    fun thePortMustBeAPort() {
        assertEquals(Problem.PORT, draft(port = "0").problem(stored))
        assertEquals(Problem.PORT, draft(port = "65536").problem(stored))
        assertEquals(Problem.PORT, draft(port = "ochenta").problem(stored))
        assertNull(draft(port = " 22 ").problem(stored))
    }

    @Test
    fun theAddressMustBeOneWeWillTalkTo() {
        assertEquals(Problem.ADDRESS, draft(address = "192.168.1.10").problem(stored))
        assertEquals(Problem.ADDRESS, draft(address = "").problem(stored))
    }

    @Test
    fun anotherMachineAtTheSameAddressIsADuplicate() {
        assertEquals(Problem.DUPLICATE, draft(address = "100.123.234.20").problem(stored))
        // A different port is a different endpoint, so it is not the same machine.
        assertNull(draft(address = "100.123.234.20", port = "58466").problem(stored))
    }

    @Test
    fun aMachineBeingEditedIsNotADuplicateOfItself() {
        // Renaming without touching the address is the common edit and has to be allowed.
        assertNull(draft(name = "MINIPC del salon", address = "100.123.234.20").problem(stored, editing = "minipc"))
        // Moving it onto another stored machine is still a conflict.
        assertEquals(Problem.DUPLICATE, draft(address = "100.120.128.58").problem(stored, editing = "minipc"))
    }

    @Test
    fun editingKeepsTheIdSoNothingTiedToItIsLost() {
        val moved = draft(name = "MINIPC Linux", address = "100.123.234.21").machine(minipc.id)
        assertEquals(minipc.id, moved.id)
        assertEquals("100.123.234.21", moved.endpoint.host)
    }
}
