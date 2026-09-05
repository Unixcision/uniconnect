package com.unixcision.uniconnect.android.domain.vt

/** Streaming UTF-8 decoder: bytes may arrive split across chunks; malformed input becomes U+FFFD. */
class Utf8Decoder {
    private var pending = 0
    private var needed = 0
    private var codePoint = 0
    private var minimum = 0

    fun decode(bytes: ByteArray, onCodePoint: (Int) -> Unit) {
        for (raw in bytes) {
            val b = raw.toInt() and 0xFF
            if (needed > 0) {
                if (b and 0xC0 == 0x80) {
                    codePoint = (codePoint shl 6) or (b and 0x3F)
                    if (--needed == 0) {
                        onCodePoint(if (codePoint < minimum || codePoint > 0x10FFFF || codePoint in 0xD800..0xDFFF) 0xFFFD else codePoint)
                        codePoint = 0
                    }
                    continue
                }
                needed = 0; codePoint = 0
                onCodePoint(0xFFFD)
                // Fall through: the byte that broke the sequence starts a new one.
            }
            when {
                b < 0x80 -> onCodePoint(b)
                b and 0xE0 == 0xC0 -> { codePoint = b and 0x1F; needed = 1; minimum = 0x80 }
                b and 0xF0 == 0xE0 -> { codePoint = b and 0x0F; needed = 2; minimum = 0x800 }
                b and 0xF8 == 0xF0 -> { codePoint = b and 0x07; needed = 3; minimum = 0x10000 }
                else -> onCodePoint(0xFFFD)
            }
        }
        pending = needed
    }

    /** True while the last chunk ended in the middle of a multi-byte sequence. */
    val hasPartial: Boolean get() = pending > 0
}
