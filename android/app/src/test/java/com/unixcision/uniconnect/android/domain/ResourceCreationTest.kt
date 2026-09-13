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

    @Test fun aWrittenConnectionIsItsOwnShapeAndNeverTravelsWithAnInheritedOneOrAFolder() {
        assertTrue(ResourceCreation.Workspace("ELTEMPLO", null, null, connectCommand = "ssh root@eltemploacademy.com").isValid())
        assertTrue(ResourceCreation.Workspace("VPS", null, null, connectCommand = "sshpass -p 'clave' ssh dani@ejemplo.com").isValid())
        // One box, one way of connecting: a written command cannot arrive alongside an inherited
        // credential or a local folder, because the machine would have to guess which one wins.
        assertFalse(ResourceCreation.Workspace("VPS", null, "otra-caja", connectCommand = "ssh root@ejemplo.com").isValid())
        assertFalse(ResourceCreation.Workspace("VPS", "/home/dani", null, connectCommand = "ssh root@ejemplo.com").isValid())
    }

    @Test fun aConnectionCommandIsRefusedHereOnlyWhenItCouldNeverBeOne() {
        // What is safe is the machine's call: it owns the parser and the vault. The phone stops
        // what no machine could ever accept, and nothing else.
        assertFalse(ResourceCreation.Workspace("VPS", null, null, connectCommand = "").isValid())
        assertFalse(ResourceCreation.Workspace("VPS", null, null, connectCommand = " ssh root@x ").isValid())
        assertFalse(ResourceCreation.Workspace("VPS", null, null, connectCommand = "ssh root@x\nrm -rf /").isValid())
        assertFalse(ResourceCreation.Workspace("VPS", null, null, connectCommand = "ssh root@x\u0000").isValid())
        assertFalse(ResourceCreation.Workspace("VPS", null, null, connectCommand = "ssh " + "a".repeat(4096)).isValid())
        // A command the machine will reject is still worth sending: the machine says why.
        assertTrue(ResourceCreation.Workspace("VPS", null, null, connectCommand = "rm -rf /").isValid())
    }
}
