package com.unixcision.uniconnect.android.notifications

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Swiping a window's notification away forgets its count, so the next notice starts at one. */
class NoticeDismissReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        intent.getStringExtra(AndroidNoticePublisher.THREAD)?.let(NoticeCounters::clear)
    }
}
