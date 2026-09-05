package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AgentCreationTest {
    private val terminal = RemoteAgentTarget("terminal", "Terminal")
    private val custom = RemoteAgentTarget("custom:review-team", "Revisión del equipo")
    private val local = RemoteWorkspace("local", "Proyecto", false, emptyList(), listOf(terminal, custom))

    @Test fun localCreationUsesTheExactAdvertisedAgentInsteadOfAssumingBuiltIns() {
        val request = ResourceCreation.Terminal(local.id, "Revisión", "/proyecto", null, custom.id)
        assertTrue(request.isAllowedIn(local))
        assertFalse(request.copy(agentID = "claude").isAllowedIn(local))
        assertEquals("terminal", ResourceCreation.Terminal(local.id, "Consola", null, null).agentID)
    }

    @Test fun removedOrMissingCatalogDoesNotSilentlySubstituteAnotherAgent() {
        val request = ResourceCreation.Terminal(local.id, "Revisión", null, null, custom.id)
        assertFalse(request.isAllowedIn(local.copy(availableAgentTargets = listOf(terminal))))
        assertFalse(request.isAllowedIn(local.copy(availableAgentTargets = emptyList())))
        assertFalse(request.isAllowedIn(local.copy(id = "another-workspace")))
    }

    @Test fun sshCreationKeepsTheTmuxContractAndDoesNotLaunchALocalAgent() {
        val ssh = RemoteWorkspace("ssh", "Servidor", true, emptyList(), listOf(terminal))
        val request = ResourceCreation.Terminal(ssh.id, "Consola", null, "app4")
        assertTrue(request.isAllowedIn(ssh))
        assertFalse(request.copy(agentID = custom.id).isAllowedIn(ssh))
        assertFalse(request.copy(tmuxSession = null).isAllowedIn(ssh))
        assertFalse(ResourceCreation.Terminal(local.id, "Consola", null, "app4").isAllowedIn(local))
    }
}
