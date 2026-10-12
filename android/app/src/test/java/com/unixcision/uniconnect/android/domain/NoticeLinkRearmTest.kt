package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The notice links the user asked for come back on their own when the app returns to the
 * foreground. Turning UniConnect's notifications back on in Android and returning to the app is
 * enough; a link that runs, failed for another reason or waits for approval is left alone.
 */
class NoticeLinkRearmTest {
    @Test
    fun aRememberedLinkWithNothingRunningIsRearmed() {
        assertEquals(listOf("mac"), NoticeLinkRearm.machines(setOf("mac"), emptyMap()))
    }

    @Test
    fun aLinkHeldBackByBlockedNotificationsIsRearmedOnReturn() {
        val states = mapOf("mac" to NotificationLinkState.NotificationsBlocked)
        assertEquals(listOf("mac"), NoticeLinkRearm.machines(setOf("mac"), states))
    }

    @Test
    fun runningFailedOrPendingApprovalLinksAreLeftAlone() {
        val states = mapOf(
            "conectando" to NotificationLinkState.Connecting,
            "conectado" to NotificationLinkState.Connected,
            "reconectando" to NotificationLinkState.Reconnecting,
            "aprobar" to NotificationLinkState.ApprovalRequired,
            "fallido" to NotificationLinkState.Failed,
        )
        assertEquals(emptyList<String>(), NoticeLinkRearm.machines(states.keys, states))
    }

    @Test
    fun onlyRememberedLinksAreConsidered() {
        val states = mapOf("olvidado" to NotificationLinkState.NotificationsBlocked)
        assertEquals(emptyList<String>(), NoticeLinkRearm.machines(emptySet(), states))
    }
}
