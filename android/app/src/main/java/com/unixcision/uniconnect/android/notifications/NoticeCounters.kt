package com.unixcision.uniconnect.android.notifications

import java.util.concurrent.ConcurrentHashMap

/**
 * How many notices each window has raised since the reader last looked.
 *
 * One notification per window is shown and updated in place; the count is what makes "(40)"
 * possible. Cleared when the notification is opened or swiped away. In memory only: after a
 * process death the count starts again, which errs on the quiet side.
 */
object NoticeCounters {
    private val counts = ConcurrentHashMap<String, Int>()

    fun increment(thread: String): Int = counts.merge(thread, 1, Int::plus) ?: 1

    fun clear(thread: String) { counts.remove(thread) }

    fun current(thread: String): Int = counts[thread] ?: 0
}
