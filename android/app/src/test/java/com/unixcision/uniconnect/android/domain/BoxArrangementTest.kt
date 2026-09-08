package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Test

/** Favourites first, the reader's order on top of the host's, and moving without losing anyone. */
class BoxArrangementTest {
    private data class Box(val id: String, val pinned: Boolean = false)
    private fun ids(boxes: List<Box>) = boxes.map { it.id }
    private val host = listOf(Box("a"), Box("b", pinned = true), Box("c"), Box("d"))

    @Test
    fun favouritesComeFirstKeepingTheHostOrderOtherwise() {
        assertEquals(listOf("b", "a", "c", "d"), ids(BoxArrangement.arrange(host, { it.id }, { it.pinned }, emptySet(), emptyList())))
    }

    @Test
    fun aLocalFavouriteCountsLikeTheHostsOwn() {
        assertEquals(listOf("b", "d", "a", "c"), ids(BoxArrangement.arrange(host, { it.id }, { it.pinned }, setOf("d"), emptyList())))
    }

    @Test
    fun aLocalOrderWinsAndUnknownIdsFollowInHostOrder() {
        val arranged = BoxArrangement.arrange(host, { it.id }, { false }, emptySet(), listOf("c", "a"))
        assertEquals(listOf("c", "a", "b", "d"), ids(arranged))
    }

    @Test
    fun movingStaysWithinBoundsAndKeepsEveryone() {
        assertEquals(listOf("b", "a", "c"), BoxArrangement.moved(listOf("a", "b", "c"), "b", -1))
        assertEquals(listOf("a", "b", "c"), BoxArrangement.moved(listOf("a", "b", "c"), "a", -5))
        assertEquals(listOf("b", "c", "a"), BoxArrangement.moved(listOf("a", "b", "c"), "a", 9))
        assertEquals(listOf("c", "a", "b"), BoxArrangement.movedToTop(listOf("a", "b", "c"), "c"))
    }
}
