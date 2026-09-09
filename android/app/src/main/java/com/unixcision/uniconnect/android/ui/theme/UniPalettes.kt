package com.unixcision.uniconnect.android.ui.theme

import androidx.compose.ui.graphics.Color

/**
 * The eight palettes: four themes, each light and dark. Only [UniTokens.tokensFor] reads them.
 *
 * Light palettes carry dark, saturated tones so a monogram reads on a pale ground; dark palettes
 * carry the pale ones. Slot order is the same in every list, so a box keeps its colour family.
 */
internal object UniPalettes {
    // Sereno: warm neutrals, a calm teal accent and a soft lavender second accent.
    val serenoLight = UniColors(
        isDark = false,
        background = Color(0xFFF7F6F2), surface = Color(0xFFFFFFFF), surfaceRaised = Color(0xFFEFEDE7),
        outline = Color(0xFFE2DFD8), text = Color(0xFF1F1E1B), muted = Color(0xFF6E6B64),
        accent = Color(0xFF2F7D6F), onAccent = Color(0xFFFFFFFF), accentSoft = Color(0xFF6B5FA8),
        success = Color(0xFF2E8B57), warning = Color(0xFFB8781A), danger = Color(0xFFC8463F),
        glassTop = Color(0x99FFFFFF), glassBottom = Color(0x33FFFFFF),
        tones = listOf(
            Color(0xFF0F766E), Color(0xFF6D5BD0), Color(0xFF0E7490), Color(0xFFB45309),
            Color(0xFFBE123C), Color(0xFF1D4ED8), Color(0xFFA21CAF), Color(0xFF4D7C0F),
        ),
    )
    val serenoDark = UniColors(
        isDark = true,
        background = Color(0xFF1B1A17), surface = Color(0xFF24231F), surfaceRaised = Color(0xFF2E2C27),
        outline = Color(0xFF3A3833), text = Color(0xFFECE9E2), muted = Color(0xFFA39F95),
        accent = Color(0xFF6FC7B8), onAccent = Color(0xFF15201D), accentSoft = Color(0xFFB3A7E6),
        success = Color(0xFF7BD3A0), warning = Color(0xFFE9B85B), danger = Color(0xFFF08A82),
        glassTop = Color(0x24FFFFFF), glassBottom = Color(0x0AFFFFFF),
        tones = listOf(
            Color(0xFF5EEAD4), Color(0xFFA78BFA), Color(0xFF67E8F9), Color(0xFFFCD34D),
            Color(0xFFFB7185), Color(0xFF93C5FD), Color(0xFFF0ABFC), Color(0xFFBEF264),
        ),
    )

    // Señal: paper white or ink black, electric indigo, state colours that read at a glance.
    val senalLight = UniColors(
        isDark = false,
        background = Color(0xFFFFFFFF), surface = Color(0xFFFFFFFF), surfaceRaised = Color(0xFFF3F4F7),
        outline = Color(0xFFE3E5EA), text = Color(0xFF0B0F1A), muted = Color(0xFF5B6270),
        accent = Color(0xFF4F46E5), onAccent = Color(0xFFFFFFFF), accentSoft = Color(0xFF6D6AF2),
        success = Color(0xFF16A34A), warning = Color(0xFFD97706), danger = Color(0xFFDC2626),
        glassTop = Color(0xB3FFFFFF), glassBottom = Color(0x4DFFFFFF),
        tones = listOf(
            Color(0xFF4F46E5), Color(0xFF0891B2), Color(0xFF059669), Color(0xFFD97706),
            Color(0xFFDC2626), Color(0xFF2563EB), Color(0xFFC026D3), Color(0xFF65A30D),
        ),
    )
    val senalDark = UniColors(
        isDark = true,
        background = Color(0xFF0B0D12), surface = Color(0xFF12151C), surfaceRaised = Color(0xFF1A1E27),
        outline = Color(0xFF272C37), text = Color(0xFFF3F4F6), muted = Color(0xFF9AA1AE),
        accent = Color(0xFF818CF8), onAccent = Color(0xFF0B0D12), accentSoft = Color(0xFFA5B4FC),
        success = Color(0xFF4ADE80), warning = Color(0xFFFBBF24), danger = Color(0xFFF87171),
        glassTop = Color(0x1AFFFFFF), glassBottom = Color(0x08FFFFFF),
        tones = listOf(
            Color(0xFF818CF8), Color(0xFF22D3EE), Color(0xFF34D399), Color(0xFFFBBF24),
            Color(0xFFF87171), Color(0xFF60A5FA), Color(0xFFE879F9), Color(0xFFA3E635),
        ),
    )

    // Tinta: paper and ink, copper accent, bronze second accent, contrast before decoration.
    val tintaLight = UniColors(
        isDark = false,
        background = Color(0xFFFBF8F3), surface = Color(0xFFFBF8F3), surfaceRaised = Color(0xFFF1ECE3),
        outline = Color(0xFFC9C2B6), text = Color(0xFF141210), muted = Color(0xFF5E584F),
        accent = Color(0xFFB5652A), onAccent = Color(0xFFFFFFFF), accentSoft = Color(0xFF8A6A4B),
        success = Color(0xFF2F6B3A), warning = Color(0xFFA8720F), danger = Color(0xFFA8322A),
        glassTop = Color(0x80FFFFFF), glassBottom = Color(0x33FFFFFF),
        tones = listOf(
            Color(0xFFB5652A), Color(0xFF7A4E9A), Color(0xFF2F6B3A), Color(0xFFA8322A),
            Color(0xFF1F5F8B), Color(0xFF8C6D1F), Color(0xFF5B4B3A), Color(0xFF2F5D50),
        ),
    )
    val tintaDark = UniColors(
        isDark = true,
        background = Color(0xFF121110), surface = Color(0xFF121110), surfaceRaised = Color(0xFF1D1B18),
        outline = Color(0xFF3D3934), text = Color(0xFFF2EDE4), muted = Color(0xFFA9A197),
        accent = Color(0xFFD98B4E), onAccent = Color(0xFF1A130C), accentSoft = Color(0xFFC4A484),
        success = Color(0xFF7BC08A), warning = Color(0xFFE0B04C), danger = Color(0xFFE5776C),
        glassTop = Color(0x1FFFFFFF), glassBottom = Color(0x08FFFFFF),
        tones = listOf(
            Color(0xFFD98B4E), Color(0xFFB497D6), Color(0xFF7BC08A), Color(0xFFE5776C),
            Color(0xFF7FB3D5), Color(0xFFD1B25A), Color(0xFFC4A484), Color(0xFF8CBFAE),
        ),
    )

    // Terminal: graphite grounds, a muted phosphor green, cool grey-teal as the second accent.
    val terminalLight = UniColors(
        isDark = false,
        background = Color(0xFFECEEEC), surface = Color(0xFFF5F7F5), surfaceRaised = Color(0xFFDFE3E0),
        outline = Color(0xFFC3C9C5), text = Color(0xFF161A17), muted = Color(0xFF5D6660),
        accent = Color(0xFF2E7D4F), onAccent = Color(0xFFFFFFFF), accentSoft = Color(0xFF4F7F72),
        success = Color(0xFF2E7D4F), warning = Color(0xFFA9781A), danger = Color(0xFFB23B3B),
        glassTop = Color(0x8CFFFFFF), glassBottom = Color(0x33FFFFFF),
        tones = listOf(
            Color(0xFF2E7D4F), Color(0xFF2B6CB0), Color(0xFF8A5A00), Color(0xFFB23B3B),
            Color(0xFF5E60A8), Color(0xFF0E7490), Color(0xFF6B7280), Color(0xFF7C5E10),
        ),
    )
    val terminalDark = UniColors(
        isDark = true,
        background = Color(0xFF16191A), surface = Color(0xFF1D2123), surfaceRaised = Color(0xFF262B2D),
        outline = Color(0xFF343A3C), text = Color(0xFFDDE3DE), muted = Color(0xFF8B948E),
        accent = Color(0xFF7FD69A), onAccent = Color(0xFF0F1A13), accentSoft = Color(0xFF9AB8A8),
        success = Color(0xFF7FD69A), warning = Color(0xFFE2B65A), danger = Color(0xFFE57373),
        glassTop = Color(0x14FFFFFF), glassBottom = Color(0x05FFFFFF),
        tones = listOf(
            Color(0xFF7FD69A), Color(0xFF7EB6F0), Color(0xFFE2B65A), Color(0xFFE57373),
            Color(0xFFB0A8F0), Color(0xFF67E8F9), Color(0xFF9CA3AF), Color(0xFFD4C070),
        ),
    )
}
