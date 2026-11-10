package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Close, run as and «Recientes» are offered only when the machine announces each one. */
class MachineSnapshotCapabilitiesTest {
    private fun snapshot(vararg capabilities: String) = MachineSnapshot("Mac", emptyList(), capabilities.toSet())

    @Test fun eachCapabilityTurnsOnItsOwnFeatureAndNoOther() {
        snapshot(MachineSnapshot.BOX_CLOSE).let { assertTrue(it.closesBoxes); assertFalse(it.runsAs); assertFalse(it.listsRecentPrompts) }
        snapshot(MachineSnapshot.RUN_AS).let { assertFalse(it.closesBoxes); assertTrue(it.runsAs); assertFalse(it.listsRecentPrompts) }
        snapshot(MachineSnapshot.RECENT_PROMPTS).let { assertFalse(it.closesBoxes); assertFalse(it.runsAs); assertTrue(it.listsRecentPrompts) }
    }

    @Test fun aMachineThatAnnouncesNothingOffersNoneOfThem() {
        val old = snapshot("box_update", "relaunch.v1")
        assertFalse(old.closesBoxes)
        assertFalse(old.runsAs)
        assertFalse(old.listsRecentPrompts)
    }

    @Test fun theNamesAreTheOnesOnTheWire() {
        val announced = snapshot("box_close", "run_as", "recent_prompts")
        assertTrue(announced.closesBoxes && announced.runsAs && announced.listsRecentPrompts)
    }

    @Test fun accountsAreListedOnlyWhenTheMachineAnnouncesAccountsV1() {
        assertTrue(snapshot("accounts.v1").listsAccounts)
        assertFalse(snapshot("box_update", "relaunch.v1", "window_details.v1").listsAccounts)
        assertFalse(snapshot("accounts").listsAccounts)
    }
}
