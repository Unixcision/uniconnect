package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ResourceCreationTest {
    @Test fun localWorkspaceRequiresAnAbsoluteFolderButSshInheritsAnExistingSource() {
        assertTrue(ResourceCreation.Workspace("Proyecto", "/home/dani/proyecto", null).isValid())
        assertFalse(ResourceCreation.Workspace("Proyecto", "proyecto", null).isValid())
        assertFalse(ResourceCreation.Workspace("Proyecto", null, null).isValid())
        assertTrue(ResourceCreation.Workspace("Proyecto SSH", null, "workspace-host-owned-id").isValid())
    }

    @Test fun tmuxNamesMustSurviveTheHostCanonicalizationUnchanged() {
        listOf("app4", "app-4", "_agente", "a".repeat(40)).forEach {
            assertTrue(ResourceCreation.Terminal("workspace", "APP 4", null, it).isValid())
        }
        listOf("", "App4", "-app", "app-", "app:4", "a".repeat(41), "app;whoami").forEach {
            assertFalse(ResourceCreation.Terminal("workspace", "APP 4", null, it).isValid())
        }
        assertTrue(ResourceCreation.Terminal("workspace", "Terminal local", null, null).isValid())
    }

    @Test fun controlCharactersAndOversizedPathsAreRejectedBeforeAnyMutation() {
        assertFalse(ResourceCreation.Workspace("nombre\ninvalido", "/tmp", null).isValid())
        assertFalse(ResourceCreation.Workspace("Proyecto", "/tmp\u0000", null).isValid())
        assertFalse(ResourceCreation.Workspace("Proyecto", "/" + "a".repeat(4096), null).isValid())
    }
}
