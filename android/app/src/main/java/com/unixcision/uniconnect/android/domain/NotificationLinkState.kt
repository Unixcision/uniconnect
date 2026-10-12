package com.unixcision.uniconnect.android.domain

/**
 * State of the private notice link with one machine.
 *
 * [NotificationsBlocked] means Android has UniConnect's notifications switched off: nothing can be
 * shown, so the link is not started until they are back on (see [NoticeLinkRearm]).
 */
enum class NotificationLinkState { Connecting, Connected, Reconnecting, ApprovalRequired, NotificationsBlocked, Failed }
