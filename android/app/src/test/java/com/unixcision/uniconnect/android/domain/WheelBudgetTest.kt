package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** A flick must never leave the terminal scrolling on its own for seconds. */
class WheelBudgetTest {
    @Test
    fun stepsInTheSameDirectionAddUpToTheCap() {
        val budget = WheelBudget(cap = 10)
        budget.add(up = true, steps = 6); budget.add(up = true, steps = 6)
        assertEquals(10, budget.pending)
    }

    @Test
    fun theOppositeDirectionCancelsWhatWasPending() {
        val budget = WheelBudget(cap = 10)
        budget.add(up = true, steps = 8); budget.add(up = false, steps = 3)
        assertEquals(-3, budget.pending)
    }

    @Test
    fun stepsAreHandedOutOneAtATimeThenNothing() {
        val budget = WheelBudget(cap = 10)
        budget.add(up = false, steps = 2)
        assertEquals(false, budget.next()); assertEquals(false, budget.next()); assertNull(budget.next())
    }

    @Test
    fun clearingForgetsEverythingOwed() {
        val budget = WheelBudget(cap = 10)
        budget.add(up = true, steps = 9); budget.clear()
        assertNull(budget.next())
    }
}
