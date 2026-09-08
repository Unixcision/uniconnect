package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** A notice names its window when the phone has seen it, and says nothing it cannot know. */
class NoticeNamesTest {
    private val inventory = listOf(
        RemoteWorkspace("ws-1", "TB2BPRO", isSSH = true, windows = listOf(RemoteWindow("win-1", "Desarrolla TL B2B", "terminal"))),
        RemoteWorkspace("ws-2", "QA TMUX MOVIL", isSSH = false, windows = emptyList()),
    )
    private fun notice(workspace: String, window: String?) = RemoteNotice("n", workspace, window, 0L, isRead = false)

    @Test
    fun namesBothTheWorkspaceAndTheWindow() {
        assertEquals(NoticeNames("TB2BPRO", "Desarrolla TL B2B"), NoticeNames.resolve(inventory, notice("ws-1", "win-1")))
    }

    @Test
    fun aNoticeWithoutAWindowNamesJustTheWorkspace() {
        assertEquals(NoticeNames("QA TMUX MOVIL", null), NoticeNames.resolve(inventory, notice("ws-2", null)))
    }

    @Test
    fun aWindowCreatedAfterTheLastInventoryStillNamesItsWorkspace() {
        assertEquals(NoticeNames("TB2BPRO", null), NoticeNames.resolve(inventory, notice("ws-1", "win-new")))
    }

    @Test
    fun anUnknownWorkspaceNamesNothing() {
        assertTrue(NoticeNames.resolve(inventory, notice("ws-9", "win-1")).isEmpty)
        assertTrue(NoticeNames.resolve(emptyList(), notice("ws-1", "win-1")).isEmpty)
    }
}
