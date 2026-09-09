package com.unixcision.uniconnect.android.ui.theme

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.text.font.FontFamily
import com.unixcision.uniconnect.android.domain.DesignTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What every one of the eight theme readings must hold, checked through the same pure function
 * the screens use. Contrast is the WCAG ratio, so a palette that stops reading fails here.
 */
class UniTokensTest {
    private val themes = DesignTheme.entries

    @Test
    fun everyThemeHasAPaleAndADeepGround() {
        themes.forEach { theme ->
            val light = UniTokens.tokensFor(theme, dark = false).colors
            val dark = UniTokens.tokensFor(theme, dark = true).colors
            assertFalse("$theme light says so", light.isDark)
            assertTrue("$theme dark says so", dark.isDark)
            assertTrue("$theme light ground is pale", light.background.luminance() > .5f)
            assertTrue("$theme dark ground is deep", dark.background.luminance() < .15f)
            assertNotEquals("$theme changes its ground between modes", light.background, dark.background)
            assertNotEquals("$theme changes its text between modes", light.text, dark.text)
        }
    }

    @Test
    fun textAndStatesReadOnTheirGroundInBothModes() {
        themes.forEach { theme ->
            listOf(false, true).forEach { dark ->
                val c = UniTokens.tokensFor(theme, dark).colors
                val label = "$theme ${if (dark) "dark" else "light"}"
                assertTrue("$label text on background", contrast(c.text, c.background) >= 7f)
                assertTrue("$label text on surface", contrast(c.text, c.surface) >= 7f)
                assertTrue("$label muted on background", contrast(c.muted, c.background) >= 4.5f)
                assertTrue("$label accent on background", contrast(c.accent, c.background) >= 3f)
                assertTrue("$label on-accent on accent", contrast(c.onAccent, c.accent) >= 3f)
                assertTrue("$label success on background", contrast(c.success, c.background) >= 3f)
                assertTrue("$label warning on background", contrast(c.warning, c.background) >= 3f)
                assertTrue("$label danger on background", contrast(c.danger, c.background) >= 3f)
                c.tones.forEachIndexed { index, tone -> assertTrue("$label tone $index on background", contrast(tone, c.background) >= 3f) }
            }
        }
    }

    @Test
    fun everyThemeCarriesTheSameNumberOfTonesSoANameKeepsItsSlot() {
        themes.forEach { theme ->
            listOf(false, true).forEach { dark ->
                assertEquals(UniColors.TONE_COUNT, UniTokens.tokensFor(theme, dark).colors.tones.size)
            }
        }
    }

    @Test
    fun tintaSetsHeadlinesInSerifAndTheOthersDoNot() {
        assertEquals(FontFamily.Serif, UniTokens.tokensFor(DesignTheme.TINTA, dark = false).type.headlineFamily)
        assertEquals(FontFamily.Serif, UniTokens.tokensFor(DesignTheme.TINTA, dark = true).type.headlineFamily)
        (themes - DesignTheme.TINTA).forEach { theme ->
            assertNotEquals("$theme headlines are not serif", FontFamily.Serif, UniTokens.tokensFor(theme, dark = false).type.headlineFamily)
        }
    }

    @Test
    fun terminalSetsIdentifiersInMonospaceAndTheOthersDoNot() {
        assertEquals(FontFamily.Monospace, UniTokens.tokensFor(DesignTheme.TERMINAL, dark = false).type.identifierFamily)
        assertEquals(FontFamily.Monospace, UniTokens.tokensFor(DesignTheme.TERMINAL, dark = true).type.identifierFamily)
        (themes - DesignTheme.TERMINAL).forEach { theme ->
            assertNotEquals("$theme identifiers are not monospace", FontFamily.Monospace, UniTokens.tokensFor(theme, dark = true).type.identifierFamily)
        }
    }

    @Test
    fun senalIsCompactAndSerenoIsNot() {
        assertEquals(RowDensity.COMPACT, UniTokens.tokensFor(DesignTheme.SENAL, dark = false).layout.density)
        assertEquals(RowDensity.COMPACT, UniTokens.tokensFor(DesignTheme.SENAL, dark = true).layout.density)
        assertEquals(RowDensity.COMFORTABLE, UniTokens.tokensFor(DesignTheme.SERENO, dark = false).layout.density)
    }

    @Test
    fun tintaDrawsHairlinesAndTheOthersDrawCards() {
        assertEquals(CardStyle.HAIRLINE, UniTokens.tokensFor(DesignTheme.TINTA, dark = false).layout.cardsAs)
        (themes - DesignTheme.TINTA).forEach { theme ->
            assertEquals("$theme draws cards", CardStyle.CARD, UniTokens.tokensFor(theme, dark = false).layout.cardsAs)
        }
    }

    @Test
    fun senalAndTintaSeparateRowsWithHairlines() {
        assertEquals(CardStyle.HAIRLINE, UniTokens.tokensFor(DesignTheme.SENAL, dark = true).layout.rowsAs)
        assertEquals(CardStyle.HAIRLINE, UniTokens.tokensFor(DesignTheme.TINTA, dark = true).layout.rowsAs)
        assertEquals(CardStyle.CARD, UniTokens.tokensFor(DesignTheme.SERENO, dark = true).layout.rowsAs)
        assertEquals(CardStyle.CARD, UniTokens.tokensFor(DesignTheme.TERMINAL, dark = true).layout.rowsAs)
    }

    @Test
    fun boxesAreARailInSerenoAndAGridOfTheAgreedColumnsElsewhere() {
        assertEquals(WorkspaceLayout.RAIL, UniTokens.tokensFor(DesignTheme.SERENO, dark = false).layout.workspacesAs)
        listOf(DesignTheme.SENAL to 2, DesignTheme.TINTA to 1, DesignTheme.TERMINAL to 3).forEach { (theme, columns) ->
            val layout = UniTokens.tokensFor(theme, dark = false).layout
            assertEquals("$theme is a grid", WorkspaceLayout.GRID, layout.workspacesAs)
            assertEquals("$theme columns", columns, layout.workspaceColumns)
        }
    }

    @Test
    fun accentSoftIsATintNotAColourOfItsOwn() {
        themes.forEach { theme ->
            listOf(false, true).forEach { dark ->
                val c = UniTokens.tokensFor(theme, dark).colors
                assertTrue("$theme accentSoft is translucent", c.accentSoft.alpha < .5f)
                assertEquals("$theme accentSoft is the accent", c.accent.copy(alpha = c.accentSoft.alpha), c.accentSoft)
                assertTrue("$theme outline is translucent", c.outline.alpha < .5f)
            }
        }
    }

    @Test
    fun layoutAndShapeDoNotDependOnTheMode() {
        themes.forEach { theme ->
            val light = UniTokens.tokensFor(theme, dark = false)
            val dark = UniTokens.tokensFor(theme, dark = true)
            assertEquals("$theme layout", light.layout, dark.layout)
            assertEquals("$theme shapes", light.shapes, dark.shapes)
            assertEquals("$theme spacing", light.spacing, dark.spacing)
            assertEquals("$theme type", light.type, dark.type)
        }
    }

    @Test
    fun radiiFollowTheBrief() {
        assertEquals(24f, UniTokens.tokensFor(DesignTheme.SERENO, dark = false).shapes.cardRadius.value)
        assertEquals(12f, UniTokens.tokensFor(DesignTheme.SENAL, dark = false).shapes.cardRadius.value)
        assertEquals(4f, UniTokens.tokensFor(DesignTheme.TINTA, dark = false).shapes.cardRadius.value)
        assertEquals(8f, UniTokens.tokensFor(DesignTheme.TERMINAL, dark = false).shapes.cardRadius.value)
    }

    /** WCAG contrast ratio between two opaque colours. */
    private fun contrast(a: Color, b: Color): Float {
        val la = a.luminance() + .05f
        val lb = b.luminance() + .05f
        return maxOf(la, lb) / minOf(la, lb)
    }
}
