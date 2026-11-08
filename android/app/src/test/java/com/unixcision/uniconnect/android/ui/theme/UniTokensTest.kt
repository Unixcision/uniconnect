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
    fun arenaSetsHeadlinesInSerifAndTheOthersDoNot() {
        assertEquals(FontFamily.Serif, UniTokens.tokensFor(DesignTheme.ARENA, dark = false).type.headlineFamily)
        assertEquals(FontFamily.Serif, UniTokens.tokensFor(DesignTheme.ARENA, dark = true).type.headlineFamily)
        (themes - DesignTheme.ARENA).forEach { theme ->
            assertNotEquals("$theme headlines are not serif", FontFamily.Serif, UniTokens.tokensFor(theme, dark = false).type.headlineFamily)
        }
    }

    @Test
    fun limaSetsIdentifiersInMonospaceAndTheOthersDoNot() {
        assertEquals(FontFamily.Monospace, UniTokens.tokensFor(DesignTheme.LIMA, dark = false).type.identifierFamily)
        assertEquals(FontFamily.Monospace, UniTokens.tokensFor(DesignTheme.LIMA, dark = true).type.identifierFamily)
        (themes - DesignTheme.LIMA).forEach { theme ->
            assertNotEquals("$theme identifiers are not monospace", FontFamily.Monospace, UniTokens.tokensFor(theme, dark = true).type.identifierFamily)
        }
    }

    @Test
    fun obsidianaIsCompactAndTheOthersLeaveAir() {
        listOf(false, true).forEach { dark ->
            assertEquals(RowDensity.COMPACT, UniTokens.tokensFor(DesignTheme.OBSIDIANA, dark).layout.density)
            (themes - DesignTheme.OBSIDIANA).forEach { theme ->
                assertEquals("$theme dark=$dark leaves air around a row", RowDensity.COMFORTABLE, UniTokens.tokensFor(theme, dark).layout.density)
            }
        }
    }

    @Test
    fun everyThemeDrawsItsMessageBlocksAsCards() {
        themes.forEach { theme -> assertEquals("$theme draws cards", CardStyle.CARD, UniTokens.tokensFor(theme, dark = false).layout.cardsAs) }
    }

    @Test
    fun onlyObsidianaSeparatesRowsWithHairlines() {
        assertEquals(CardStyle.HAIRLINE, UniTokens.tokensFor(DesignTheme.OBSIDIANA, dark = true).layout.rowsAs)
        (themes - DesignTheme.OBSIDIANA).forEach { theme ->
            assertEquals("$theme rows are cards", CardStyle.CARD, UniTokens.tokensFor(theme, dark = true).layout.rowsAs)
        }
    }

    @Test
    fun boxesAreARailInNieveAndArenaAndATwoColumnGridInObsidianaAndLima() {
        listOf(DesignTheme.NIEVE, DesignTheme.ARENA).forEach { theme ->
            assertEquals("$theme is a rail", WorkspaceLayout.RAIL, UniTokens.tokensFor(theme, dark = false).layout.workspacesAs)
        }
        listOf(DesignTheme.OBSIDIANA, DesignTheme.LIMA).forEach { theme ->
            val layout = UniTokens.tokensFor(theme, dark = false).layout
            assertEquals("$theme is a grid", WorkspaceLayout.GRID, layout.workspacesAs)
            assertEquals("$theme columns", 2, layout.workspaceColumns)
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
        assertEquals(28f, UniTokens.tokensFor(DesignTheme.NIEVE, dark = false).shapes.cardRadius.value)
        assertEquals(14f, UniTokens.tokensFor(DesignTheme.OBSIDIANA, dark = false).shapes.cardRadius.value)
        assertEquals(22f, UniTokens.tokensFor(DesignTheme.ARENA, dark = false).shapes.cardRadius.value)
        assertEquals(24f, UniTokens.tokensFor(DesignTheme.LIMA, dark = false).shapes.cardRadius.value)
    }

    @Test
    fun nieveRoundsHarderThanEveryOtherThemeAndItsChipsAndButtonsArePills() {
        val nieve = UniTokens.tokensFor(DesignTheme.NIEVE, dark = false).shapes
        (themes - DesignTheme.NIEVE).forEach { theme ->
            val other = UniTokens.tokensFor(theme, dark = false).shapes
            assertTrue("$theme cards round less than nieve", other.cardRadius.value < nieve.cardRadius.value)
        }
        // A pill is any radius past half the height of what it wraps; 999 dp is how a shape says so.
        assertTrue("nieve chips are pills", nieve.chipRadius.value >= 999f)
        assertTrue("nieve buttons are pills", nieve.buttonRadius.value >= 999f)
        assertTrue("nieve sheets round at least as hard as its cards", nieve.sheetRadius >= nieve.cardRadius)
        // A floating label has nowhere to sit in the notch of a pill, so the field steps back.
        assertTrue("nieve fields are not pills", nieve.fieldRadius < nieve.buttonRadius)
        (themes - DesignTheme.NIEVE).forEach { theme ->
            val other = UniTokens.tokensFor(theme, dark = false).shapes
            assertEquals("$theme fields follow its buttons", other.buttonRadius, other.fieldRadius)
        }
    }

    @Test
    fun nieveLeavesMoreAirBetweenBlocksThanTheThemeItIsClosestTo() {
        val nieve = UniTokens.tokensFor(DesignTheme.NIEVE, dark = false).spacing
        val arena = UniTokens.tokensFor(DesignTheme.ARENA, dark = false).spacing
        assertTrue("nieve keeps a wide page margin", nieve.page.value >= 20f)
        assertTrue("nieve separates blocks more than arena", nieve.gap > arena.gap)
        assertTrue("nieve separates things inside a row more than arena", nieve.gapSmall > arena.gapSmall)
    }

    @Test
    fun onlyNieveAndArenaSeparateASurfaceWithLight() {
        val floating = setOf(DesignTheme.NIEVE, DesignTheme.ARENA)
        floating.forEach { theme ->
            listOf(false, true).forEach { dark ->
                assertTrue("$theme dark=$dark floats", UniTokens.tokensFor(theme, dark).elevation.floats)
            }
        }
        (themes - floating).forEach { theme ->
            listOf(false, true).forEach { dark ->
                val elevation = UniTokens.tokensFor(theme, dark).elevation
                assertFalse("$theme dark=$dark stays flat", elevation.floats)
                assertEquals("$theme dark=$dark keeps its one pixel edge", UniElevation.flat, elevation)
            }
        }
    }

    @Test
    fun nieveCastsTwoLayersInTheLightAndLiftsItsSurfacesInTheDark() {
        val light = UniTokens.tokensFor(DesignTheme.NIEVE, dark = false).elevation
        assertTrue("the wide layer spreads further than the short one", light.ambient > light.key)
        assertTrue("the short layer is there at all", light.key.value > 0f)
        assertTrue("the wide layer is the fainter of the two", light.ambientColor.alpha < light.keyColor.alpha)
        assertEquals("a lit ground needs no lift", 0f, light.surfaceLift)

        val dark = UniTokens.tokensFor(DesignTheme.NIEVE, dark = true).elevation
        assertEquals("no wide layer on a dark ground", 0f, dark.ambient.value)
        assertEquals("no short layer on a dark ground", 0f, dark.key.value)
        assertTrue("a dark ground lifts instead", dark.surfaceLift > 0f)
        assertTrue("the lift stays a whisper", dark.surfaceLift < .15f)
    }

    @Test
    fun nieveKeepsItsEdgeBelowAPixelInBothModes() {
        listOf(false, true).forEach { dark ->
            val hairline = UniTokens.tokensFor(DesignTheme.NIEVE, dark).elevation.hairline
            assertTrue("nieve dark=$dark draws barely an edge", hairline.value > 0f && hairline.value < 1f)
        }
    }

    @Test
    fun onlyNieveNamesItsSectionsQuietlyAndNoneOfItsLabelsShout() {
        listOf(false, true).forEach { dark ->
            val type = UniTokens.tokensFor(DesignTheme.NIEVE, dark).type
            assertTrue("nieve dark=$dark labels are quiet", type.labelQuiet)
            assertFalse("nieve dark=$dark does not force capitals", type.labelUppercase)
        }
        (themes - DesignTheme.NIEVE).forEach { theme ->
            assertFalse("$theme labels keep their accent", UniTokens.tokensFor(theme, dark = false).type.labelQuiet)
        }
    }

    /** WCAG contrast ratio between two opaque colours. */
    private fun contrast(a: Color, b: Color): Float {
        val la = a.luminance() + .05f
        val lb = b.luminance() + .05f
        return maxOf(la, lb) / minOf(la, lb)
    }

    @Test
    fun arenaCastsAWarmShadowInTheLightAndLiftsInTheDark() {
        val light = UniTokens.tokensFor(DesignTheme.ARENA, dark = false)
        assertTrue("the warm shadow spreads", light.elevation.ambient.value > 0f)
        assertTrue("the shadow is brown, not black", light.elevation.ambientColor.red > light.elevation.ambientColor.blue)
        val dark = UniTokens.tokensFor(DesignTheme.ARENA, dark = true).elevation
        assertEquals("no shadow on a dark ground", 0f, dark.ambient.value)
        assertTrue("a dark ground lifts instead", dark.surfaceLift > 0f)
    }

    @Test
    fun limaOwnsTheScreenWithAnAcidLimeInTheDark() {
        val lime = UniTokens.tokensFor(DesignTheme.LIMA, dark = true).colors.accent
        assertTrue("lime is mostly green", lime.green > lime.blue && lime.green > .8f)
        assertTrue("and bright", lime.luminance() > .7f)
    }
}
