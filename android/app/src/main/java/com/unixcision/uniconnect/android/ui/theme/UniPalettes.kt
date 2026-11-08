package com.unixcision.uniconnect.android.ui.theme

import androidx.compose.ui.graphics.Color

/**
 * The eight palettes: four themes, each light and dark. Only
 * [UniTokens.tokensFor] reads them.
 *
 * Outlines are white or black at a small alpha so one rule reads on page, surface and raised
 * surface alike. Light palettes carry dark, saturated tones so a monogram reads on a pale
 * ground; dark palettes carry the pale ones. Slot order is the same in every list.
 */
internal object UniPalettes {
    private val white = Color.White
    private val black = Color.Black

    // Nieve: an off-white page with white surfaces floating on it, one graphite indigo, and
    // nothing else with a colour. In the dark it is a warm near-black with the same restraint;
    // there the ground, the surface and the raised surface are three steps of the same grey,
    // because that is what separates them where a shadow cannot.
    val nieveLight = UniColors(
        isDark = false,
        // Apple's grouped background: white groups read as groups on it, which F7F7F9 did not.
        background = Color(0xFFF2F2F7), surface = Color(0xFFFFFFFF), surfaceRaised = Color(0xFFEFEFF3),
        outline = black.copy(alpha = .05f), text = Color(0xFF0B0B10), muted = Color(0xFF6B6B73),
        accent = Color(0xFF3A5BD9), onAccent = Color(0xFFFFFFFF), accentSoft = Color(0xFF3A5BD9).copy(alpha = .12f),
        success = Color(0xFF2A8F58), warning = Color(0xFFB7791F), danger = Color(0xFFC0392F),
        tones = listOf(
            Color(0xFF3A5BD9), Color(0xFF0F766E), Color(0xFFB45309), Color(0xFFB02A5B),
            Color(0xFF1D4ED8), Color(0xFF7C3AED), Color(0xFF4D7C0F), Color(0xFF0E7490),
        ),
    )
    val nieveDark = UniColors(
        isDark = true,
        background = Color(0xFF0E0E10), surface = Color(0xFF1A1A1E), surfaceRaised = Color(0xFF232329),
        outline = white.copy(alpha = .07f), text = Color(0xFFF2F2F5), muted = Color(0xFF9A9AA4),
        accent = Color(0xFF7E9BFF), onAccent = Color(0xFF0E0E10), accentSoft = Color(0xFF7E9BFF).copy(alpha = .14f),
        success = Color(0xFF5FD08A), warning = Color(0xFFE8B45C), danger = Color(0xFFF0736B),
        tones = listOf(
            Color(0xFF7E9BFF), Color(0xFF5EEAD4), Color(0xFFFBBF24), Color(0xFFFB7185),
            Color(0xFF93C5FD), Color(0xFFC4B5FD), Color(0xFFA3E635), Color(0xFF67E8F9),
        ),
    )

    // Obsidiana: ink black and a single electric violet, like the tools engineers live in. The
    // ground, the surface and the raised surface are three close steps of the same ink, so rows
    // are told apart by a hairline, not by a card; in the light it is a cold paper with the same
    // violet, a little deeper so it still reads.
    val obsidianaLight = UniColors(
        isDark = false,
        background = Color(0xFFF6F6F8), surface = Color(0xFFFFFFFF), surfaceRaised = Color(0xFFEDEDF2),
        outline = black.copy(alpha = .08f), text = Color(0xFF111114), muted = Color(0xFF5E5E6B),
        accent = Color(0xFF6E56CF), onAccent = Color(0xFFFFFFFF), accentSoft = Color(0xFF6E56CF).copy(alpha = .12f),
        success = Color(0xFF18794E), warning = Color(0xFFA35200), danger = Color(0xFFCD2B31),
        tones = listOf(
            Color(0xFF6E56CF), Color(0xFF0E7C86), Color(0xFFB45309), Color(0xFFB0275A),
            Color(0xFF2556C7), Color(0xFF8E44AD), Color(0xFF3F7D0B), Color(0xFF0B6E99),
        ),
    )
    val obsidianaDark = UniColors(
        isDark = true,
        background = Color(0xFF0B0B0F), surface = Color(0xFF141419), surfaceRaised = Color(0xFF1D1D24),
        outline = white.copy(alpha = .08f), text = Color(0xFFEDEDF0), muted = Color(0xFF8F8F9C),
        accent = Color(0xFF9E8CFC), onAccent = Color(0xFF0B0B0F), accentSoft = Color(0xFF9E8CFC).copy(alpha = .16f),
        success = Color(0xFF3DD68C), warning = Color(0xFFF5A524), danger = Color(0xFFFF6369),
        tones = listOf(
            Color(0xFF9E8CFC), Color(0xFF5EEAD4), Color(0xFFFBBF24), Color(0xFFFB7185),
            Color(0xFF93C5FD), Color(0xFFE9A8FF), Color(0xFFA3E635), Color(0xFF67E8F9),
        ),
    )

    // Arena: a warm page of sand, terracotta as the one colour and ink-brown text, like a good
    // printed magazine. Surfaces are a lighter sand that floats on a warm shadow; in the dark the
    // page is roasted coffee, the surfaces a step lighter and the terracotta a glowing ember.
    val arenaLight = UniColors(
        isDark = false,
        background = Color(0xFFF4EFE6), surface = Color(0xFFFCF9F3), surfaceRaised = Color(0xFFEDE5D8),
        outline = Color(0xFF3D2B1F).copy(alpha = .10f), text = Color(0xFF241A13), muted = Color(0xFF6E5D50),
        accent = Color(0xFFB8502A), onAccent = Color(0xFFFFFFFF), accentSoft = Color(0xFFB8502A).copy(alpha = .12f),
        success = Color(0xFF3F7D3A), warning = Color(0xFF9A5B0E), danger = Color(0xFFB3261E),
        tones = listOf(
            Color(0xFFB8502A), Color(0xFF2F6F62), Color(0xFF8A5A12), Color(0xFF9E2F4E),
            Color(0xFF3B5BA5), Color(0xFF6D4A9C), Color(0xFF4F7A23), Color(0xFF1F6E85),
        ),
    )
    val arenaDark = UniColors(
        isDark = true,
        background = Color(0xFF1A1512), surface = Color(0xFF241E19), surfaceRaised = Color(0xFF2E2620),
        outline = white.copy(alpha = .07f), text = Color(0xFFF3EBDD), muted = Color(0xFFB2A391),
        accent = Color(0xFFE98A5E), onAccent = Color(0xFF1A1512), accentSoft = Color(0xFFE98A5E).copy(alpha = .16f),
        success = Color(0xFF8CC98A), warning = Color(0xFFE9B35F), danger = Color(0xFFF2877C),
        tones = listOf(
            Color(0xFFE98A5E), Color(0xFF7FD1BE), Color(0xFFE9C46A), Color(0xFFF28FA8),
            Color(0xFF9DB7F2), Color(0xFFC9A7F0), Color(0xFFB5D98A), Color(0xFF7FCFE3),
        ),
    )

    // Lima: bento. A deep green-black page, chunky tiles a step lighter and one acid lime that
    // owns the screen; numbers and names in monospace. In the light the page is a pale sage, the
    // tiles white and the lime darkened to an olive that still reads on it.
    val limaLight = UniColors(
        isDark = false,
        background = Color(0xFFEEF1EA), surface = Color(0xFFFFFFFF), surfaceRaised = Color(0xFFE2E8DB),
        outline = black.copy(alpha = .07f), text = Color(0xFF10140F), muted = Color(0xFF586155),
        accent = Color(0xFF3D6E0A), onAccent = Color(0xFFFFFFFF), accentSoft = Color(0xFF3D6E0A).copy(alpha = .14f),
        success = Color(0xFF237A3B), warning = Color(0xFF995400), danger = Color(0xFFC0392B),
        tones = listOf(
            Color(0xFF3D6E0A), Color(0xFF0F766E), Color(0xFFB45309), Color(0xFFB02A5B),
            Color(0xFF1D4ED8), Color(0xFF7C3AED), Color(0xFF0E7490), Color(0xFF9A3412),
        ),
    )
    val limaDark = UniColors(
        isDark = true,
        background = Color(0xFF0C0F0C), surface = Color(0xFF161B16), surfaceRaised = Color(0xFF1F261F),
        outline = white.copy(alpha = .08f), text = Color(0xFFF1F5EC), muted = Color(0xFF94A08F),
        accent = Color(0xFFC5F82A), onAccent = Color(0xFF0C0F0C), accentSoft = Color(0xFFC5F82A).copy(alpha = .16f),
        success = Color(0xFF7EE787), warning = Color(0xFFF6C34A), danger = Color(0xFFFF7B72),
        tones = listOf(
            Color(0xFFC5F82A), Color(0xFF5EEAD4), Color(0xFFFBBF24), Color(0xFFFB7185),
            Color(0xFF93C5FD), Color(0xFFC4B5FD), Color(0xFFFDBA74), Color(0xFF67E8F9),
        ),
    )
}
