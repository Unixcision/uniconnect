package com.unixcision.uniconnect.android.notifications

import com.unixcision.uniconnect.android.domain.NoticeKind
import org.junit.Assert.assertEquals
import org.junit.Test

/** One counter per window thread; opening or dismissing forgets it; unknown kinds are plain info. */
class NoticeCountersTest {
    @Test
    fun countsPerThreadAndForgetsOnClear() {
        NoticeCounters.clear("m/w/1"); NoticeCounters.clear("m/w/2")
        assertEquals(1, NoticeCounters.increment("m/w/1"))
        assertEquals(2, NoticeCounters.increment("m/w/1"))
        assertEquals(1, NoticeCounters.increment("m/w/2"))
        NoticeCounters.clear("m/w/1")
        assertEquals(0, NoticeCounters.current("m/w/1"))
        assertEquals(1, NoticeCounters.current("m/w/2"))
    }

    @Test
    fun hostWordsMapToKinds() {
        assertEquals(NoticeKind.ATTENTION, NoticeKind.parse("attention"))
        assertEquals(NoticeKind.FINISHED, NoticeKind.parse("finished"))
        assertEquals(NoticeKind.INFO, NoticeKind.parse("info"))
        assertEquals(NoticeKind.INFO, NoticeKind.parse(null))
    }
}
