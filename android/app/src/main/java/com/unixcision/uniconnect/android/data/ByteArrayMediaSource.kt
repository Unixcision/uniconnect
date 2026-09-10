package com.unixcision.uniconnect.android.data

import android.media.MediaDataSource

/**
 * A recording already in memory as something [android.media.MediaExtractor] can read.
 *
 * It exists so the decoder never needs to know where a clip was written: an
 * [com.unixcision.uniconnect.android.domain.AudioClip] hands over its bytes and nothing else, the
 * same bytes that would have travelled to a machine.
 */
class ByteArrayMediaSource(private val bytes: ByteArray) : MediaDataSource() {
    override fun readAt(position: Long, buffer: ByteArray, offset: Int, size: Int): Int {
        if (position >= bytes.size) return -1
        val available = (bytes.size - position).toInt().coerceAtMost(size)
        if (available <= 0) return -1
        System.arraycopy(bytes, position.toInt(), buffer, offset, available)
        return available
    }

    override fun getSize(): Long = bytes.size.toLong()

    override fun close() = Unit
}
