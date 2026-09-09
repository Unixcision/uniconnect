package com.unixcision.uniconnect.android.ui.theme

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** What the elevation token itself must hold, apart from any theme that uses it. */
class UniElevationTest {
    @Test
    fun theFlatReadingNeitherCastsNorLiftsAndStillDrawsItsEdge() {
        assertFalse("flat does not float", UniElevation.flat.floats)
        assertTrue("flat still draws a one pixel edge", UniElevation.flat.hairline == 1.dp)
    }

    @Test
    fun aShadowOnItsOwnFloatsAndSoDoesALiftOnItsOwn() {
        val cast = UniElevation.flat.copy(ambient = 12.dp, ambientColor = Color.Black.copy(alpha = .4f))
        val lifted = UniElevation.flat.copy(surfaceLift = .05f)
        val anchored = UniElevation.flat.copy(key = 3.dp, keyColor = Color.Black)
        assertTrue("a wide layer is enough", cast.floats)
        assertTrue("a lift is enough", lifted.floats)
        assertTrue("a short layer is enough", anchored.floats)
    }

    @Test
    fun aLiftIsAnAlphaAndARadiusIsNeverNegative() {
        assertThrows(IllegalArgumentException::class.java) { UniElevation.flat.copy(surfaceLift = 1.4f) }
        assertThrows(IllegalArgumentException::class.java) { UniElevation.flat.copy(surfaceLift = -0.1f) }
        assertThrows(IllegalArgumentException::class.java) { UniElevation.flat.copy(ambient = (-2).dp) }
        assertThrows(IllegalArgumentException::class.java) { UniElevation.flat.copy(hairline = (-1).dp) }
    }
}
