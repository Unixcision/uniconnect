package com.unixcision.uniconnect.android.ui.theme

import androidx.compose.ui.graphics.Color

/**
 * The eight palettes: four themes, each light and dark, as the design mock-ups fix them. Only
 * [UniTokens.tokensFor] reads them.
 *
 * Outlines are white or black at a small alpha so one rule reads on page, surface and raised
 * surface alike. Light palettes carry dark, saturated tones so a monogram reads on a pale
 * ground; dark palettes carry the pale ones. Slot order is the same in every list.
 */
internal object UniPalettes {
    private val white = Color.White
    private val black = Color.Black

    // Sereno: warm neutrals, sand as the accent, nothing loud.
    val serenoDark = UniColors(
        isDark = true,
        background = Color(0xFF171614), surface = Color(0xFF1F1E1B), surfaceRaised = Color(0xFF262522),
        outline = white.copy(alpha = .06f), text = Color(0xFFECE8E1), muted = Color(0xFF9C968C),
        accent = Color(0xFFD7CFC3), onAccent = Color(0xFF171614), accentSoft = Color(0xFFD7CFC3).copy(alpha = .14f),
        success = Color(0xFF6FCF97), warning = Color(0xFFE5B25D), danger = Color(0xFFE06C6C),
        tones = listOf(
            Color(0xFF5EEAD4), Color(0xFFA78BFA), Color(0xFF67E8F9), Color(0xFFFCD34D),
            Color(0xFFFB7185), Color(0xFF93C5FD), Color(0xFFF0ABFC), Color(0xFFBEF264),
        ),
    )
    val serenoLight = UniColors(
        isDark = false,
        background = Color(0xFFF7F5F1), surface = Color(0xFFFFFFFF), surfaceRaised = Color(0xFFEFECE6),
        outline = black.copy(alpha = .06f), text = Color(0xFF1F1D1A), muted = Color(0xFF6E685F),
        accent = Color(0xFF6B6259), onAccent = Color(0xFFFFFFFF), accentSoft = Color(0xFF6B6259).copy(alpha = .14f),
        success = Color(0xFF2F9E5F), warning = Color(0xFFB8842A), danger = Color(0xFFC4463F),
        tones = listOf(
            Color(0xFF0F766E), Color(0xFF6D5BD0), Color(0xFF0E7490), Color(0xFFB45309),
            Color(0xFFBE123C), Color(0xFF1D4ED8), Color(0xFFA21CAF), Color(0xFF4D7C0F),
        ),
    )

    // Señal: near-black or near-white ground, one electric indigo, state colours that read at a glance.
    val senalDark = UniColors(
        isDark = true,
        background = Color(0xFF0B0C0E), surface = Color(0xFF121417), surfaceRaised = Color(0xFF171A1F),
        outline = white.copy(alpha = .07f), text = Color(0xFFE2E8F0), muted = Color(0xFF8B93A1),
        accent = Color(0xFF5B5BD6), onAccent = Color(0xFFFFFFFF), accentSoft = Color(0xFF5B5BD6).copy(alpha = .12f),
        success = Color(0xFF22C55E), warning = Color(0xFFF59E0B), danger = Color(0xFFEF4444),
        tones = listOf(
            Color(0xFF818CF8), Color(0xFF22D3EE), Color(0xFF34D399), Color(0xFFFBBF24),
            Color(0xFFF87171), Color(0xFF60A5FA), Color(0xFFE879F9), Color(0xFFA3E635),
        ),
    )
    val senalLight = UniColors(
        isDark = false,
        background = Color(0xFFFAFAFB), surface = Color(0xFFFFFFFF), surfaceRaised = Color(0xFFF3F4F6),
        outline = black.copy(alpha = .08f), text = Color(0xFF111318), muted = Color(0xFF5B6270),
        accent = Color(0xFF4F4FC2), onAccent = Color(0xFFFFFFFF), accentSoft = Color(0xFF4F4FC2).copy(alpha = .12f),
        success = Color(0xFF16A34A), warning = Color(0xFFD97706), danger = Color(0xFFDC2626),
        tones = listOf(
            Color(0xFF4F46E5), Color(0xFF0891B2), Color(0xFF059669), Color(0xFFD97706),
            Color(0xFFDC2626), Color(0xFF2563EB), Color(0xFFC026D3), Color(0xFF4D7C0F),
        ),
    )

    // Tinta: paper and ink with a copper accent; no cards, so surface is the page itself.
    val tintaDark = UniColors(
        isDark = true,
        background = Color(0xFF121110), surface = Color(0xFF121110), surfaceRaised = Color(0xFF1C1A18),
        outline = white.copy(alpha = .14f), text = Color(0xFFF2EFE9), muted = Color(0xFFA39D93),
        accent = Color(0xFFC07A4A), onAccent = Color(0xFF121110), accentSoft = Color(0xFFC07A4A).copy(alpha = .12f),
        success = Color(0xFF8DBF7A), warning = Color(0xFFD9A441), danger = Color(0xFFD46A5A),
        tones = listOf(
            Color(0xFFD98B4E), Color(0xFFB497D6), Color(0xFF7BC08A), Color(0xFFE5776C),
            Color(0xFF7FB3D5), Color(0xFFD1B25A), Color(0xFFC4A484), Color(0xFF8CBFAE),
        ),
    )
    val tintaLight = UniColors(
        isDark = false,
        background = Color(0xFFFBF8F2), surface = Color(0xFFFBF8F2), surfaceRaised = Color(0xFFF1ECE3),
        outline = black.copy(alpha = .14f), text = Color(0xFF171411), muted = Color(0xFF6B645B),
        accent = Color(0xFFA65E2E), onAccent = Color(0xFFFFFFFF), accentSoft = Color(0xFFA65E2E).copy(alpha = .12f),
        success = Color(0xFF3F8A4C), warning = Color(0xFFA8761A), danger = Color(0xFFB5473A),
        tones = listOf(
            Color(0xFFB5652A), Color(0xFF7A4E9A), Color(0xFF2F6B3A), Color(0xFFA8322A),
            Color(0xFF1F5F8B), Color(0xFF8C6D1F), Color(0xFF5B4B3A), Color(0xFF2F5D50),
        ),
    )

    // Terminal: graphite grounds and a muted phosphor green that doubles as the success colour.
    val terminalDark = UniColors(
        isDark = true,
        background = Color(0xFF101214), surface = Color(0xFF15181B), surfaceRaised = Color(0xFF1B1F23),
        outline = white.copy(alpha = .12f), text = Color(0xFFDDE3E8), muted = Color(0xFF7F8A95),
        accent = Color(0xFF6FBF8A), onAccent = Color(0xFF101214), accentSoft = Color(0xFF6FBF8A).copy(alpha = .12f),
        success = Color(0xFF6FBF8A), warning = Color(0xFFE0B04C), danger = Color(0xFFE5675B),
        tones = listOf(
            Color(0xFF7FD69A), Color(0xFF7EB6F0), Color(0xFFE2B65A), Color(0xFFE57373),
            Color(0xFFB0A8F0), Color(0xFF67E8F9), Color(0xFF9CA3AF), Color(0xFFD4C070),
        ),
    )
    val terminalLight = UniColors(
        isDark = false,
        background = Color(0xFFF2F4F6), surface = Color(0xFFFFFFFF), surfaceRaised = Color(0xFFE9ECEF),
        outline = black.copy(alpha = .14f), text = Color(0xFF14181C), muted = Color(0xFF5D6873),
        accent = Color(0xFF2F8F5B), onAccent = Color(0xFFFFFFFF), accentSoft = Color(0xFF2F8F5B).copy(alpha = .12f),
        success = Color(0xFF2F8F5B), warning = Color(0xFFA97B12), danger = Color(0xFFC2483E),
        tones = listOf(
            Color(0xFF2E7D4F), Color(0xFF2B6CB0), Color(0xFF8A5A00), Color(0xFFB23B3B),
            Color(0xFF5E60A8), Color(0xFF0E7490), Color(0xFF6B7280), Color(0xFF7C5E10),
        ),
    )
}
