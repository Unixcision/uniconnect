package com.unixcision.uniconnect.android.domain

/**
 * Which remembered notice links to switch on again when the app comes to the foreground.
 *
 * A link the user asked for is re-armed when nothing runs for it, and also when it was held back
 * only because Android had UniConnect's notifications switched off: turning them back on and
 * returning to the app is enough. A link that runs, failed for another reason or waits for
 * approval on the machine is left alone.
 */
object NoticeLinkRearm {
    fun machines(remembered: Set<String>, states: Map<String, NotificationLinkState>): List<String> =
        remembered.filter { states[it] == null || states[it] == NotificationLinkState.NotificationsBlocked }
}
