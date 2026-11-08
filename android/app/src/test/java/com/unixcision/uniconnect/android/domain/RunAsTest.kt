package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Who a new window runs as (`run-as.v1`): what may be sent, and what is never printed. */
class RunAsTest {
    private val secret = "s3cr3t-de-dgomezm"

    @Test fun thePasswordNeverShowsInTextNotEvenInsideTheRequestThatCarriesIt() {
        val runAs = RunAs(RunAs.Mode.ROOT, RunAs.Method.SUDO, password = secret)
        assertFalse(runAs.toString().contains(secret))
        assertTrue(runAs.toString().contains("password=•••"))
        // A data class prints its fields: the request must not leak what its RunAs hides.
        val request = ResourceCreation.Terminal("w", "CLAUDE ROOT", null, null, "claude", runAs = runAs, isSandbox = true)
        assertFalse(request.toString().contains(secret))
        // Without one there is nothing to hide, and saying so is not a leak.
        assertTrue(RunAs(RunAs.Mode.ROOT).toString().contains("password=null"))
    }

    @Test fun claudeAsRootLocksIsSandboxAndNothingElseDoes() {
        assertTrue(RunAs.sandboxLocked(RunAs(RunAs.Mode.ROOT), "claude"))
        // «Otro usuario» named root is root all the same.
        assertTrue(RunAs.sandboxLocked(RunAs(RunAs.Mode.USER, RunAs.Method.SU, "root"), "claude"))
        assertFalse(RunAs.sandboxLocked(RunAs(RunAs.Mode.ROOT), "codex"))
        assertFalse(RunAs.sandboxLocked(RunAs(RunAs.Mode.USER, RunAs.Method.SU, "deploy"), "claude"))
        assertFalse(RunAs.sandboxLocked(RunAs(RunAs.Mode.CURRENT), "claude"))
        assertFalse(RunAs.sandboxLocked(null, "claude"))
        assertFalse(RunAs.sandboxLocked(RunAs(RunAs.Mode.ROOT), null))
    }

    @Test fun whatTravelsIsTheChoiceUnlessItIsLocked() {
        assertTrue(RunAs.sandboxFor(RunAs(RunAs.Mode.ROOT), "claude", chosen = false))
        assertFalse(RunAs.sandboxFor(RunAs(RunAs.Mode.ROOT), "codex", chosen = false))
        assertTrue(RunAs.sandboxFor(RunAs(RunAs.Mode.ROOT), "codex", chosen = true))
        // The box counts for the connected user too.
        assertTrue(RunAs.sandboxFor(null, "claude", chosen = true))
        assertFalse(RunAs.sandboxFor(null, "claude", chosen = false))
    }

    @Test fun onlyWhatAMachineCanTakeIsValid() {
        assertTrue(RunAs(RunAs.Mode.CURRENT).isValid())
        assertTrue(RunAs(RunAs.Mode.ROOT).isValid())
        assertTrue(RunAs(RunAs.Mode.USER, RunAs.Method.SU, "deploy", "clave").isValid())
        assertTrue(RunAs(RunAs.Mode.USER, RunAs.Method.SUDO, "www-data").isValid())
        // Another user needs a name that a sudo or su command line can take.
        assertFalse(RunAs(RunAs.Mode.USER).isValid())
        assertFalse(RunAs(RunAs.Mode.USER, user = "").isValid())
        assertFalse(RunAs(RunAs.Mode.USER, user = "-u root").isValid())
        assertFalse(RunAs(RunAs.Mode.USER, user = "dani; rm").isValid())
        assertFalse(RunAs(RunAs.Mode.ROOT, user = "deploy").isValid())
        // Spaces at either end are part of a password; a newline would answer the prompt early.
        assertTrue(RunAs(RunAs.Mode.ROOT, password = "  con espacios ").isValid())
        assertFalse(RunAs(RunAs.Mode.ROOT, password = "linea\nnueva").isValid())
        assertFalse(RunAs(RunAs.Mode.ROOT, password = "a".repeat(RunAs.MAX_PASSWORD_BYTES + 1)).isValid())
        // An empty one is the same as none: sudo without a password.
        assertTrue(RunAs(RunAs.Mode.ROOT, password = "").isValid())
    }

    @Test fun anInvalidSwitchMakesTheWholeCreationInvalid() {
        assertFalse(ResourceCreation.Terminal("w", "APP", null, null, "claude", runAs = RunAs(RunAs.Mode.USER)).isValid())
        assertTrue(ResourceCreation.Terminal("w", "APP", null, null, "claude", runAs = RunAs(RunAs.Mode.ROOT)).isValid())
    }

    @Test fun theWireNamesAreTheContracts() {
        assertEquals(listOf("current", "root", "user"), RunAs.Mode.entries.map { it.wire })
        assertEquals(listOf("sudo", "su"), RunAs.Method.entries.map { it.wire })
    }
}
