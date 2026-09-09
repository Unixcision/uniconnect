package com.unixcision.uniconnect.android.data

import android.content.ContentResolver
import android.net.Uri
import android.provider.OpenableColumns
import com.unixcision.uniconnect.android.domain.UploadFailure
import com.unixcision.uniconnect.android.domain.UploadFileName
import java.io.InputStream

/**
 * Reads what the pickers hand over: a content URI's display name and size through the provider's
 * [OpenableColumns], and its bytes on demand. The name comes back already safe to send.
 */
class ContentReader(private val resolver: ContentResolver) {
    /** What is known about a picked file before it is sent. */
    data class Description(val name: String, val size: Long)

    /** Name and size of [uri]; the size is counted by reading when the provider does not say. */
    fun describe(uri: Uri): Description {
        var name: String? = null
        var size = -1L
        runCatching {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameColumn = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val sizeColumn = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (nameColumn >= 0 && !cursor.isNull(nameColumn)) name = cursor.getString(nameColumn)
                    if (sizeColumn >= 0 && !cursor.isNull(sizeColumn)) size = cursor.getLong(sizeColumn)
                }
            }
        }
        if (size < 0) size = runCatching { resolver.openAssetFileDescriptor(uri, "r")?.use { it.length } }.getOrNull() ?: -1L
        if (size < 0) size = open(uri).use { stream ->
            val buffer = ByteArray(64 * 1024)
            var total = 0L
            while (true) { val read = stream.read(buffer); if (read < 0) break; total += read }
            total
        }
        val fallback = uri.lastPathSegment?.substringAfterLast('/')?.takeIf { it.isNotBlank() } ?: ""
        return Description(UploadFileName.sanitize(name ?: fallback), size)
    }

    /** The bytes of [uri], fresh each time so a retry starts again from the first byte. */
    fun open(uri: Uri): InputStream = try {
        resolver.openInputStream(uri) ?: throw UploadFailure.Unreadable(uri.lastPathSegment ?: uri.toString())
    } catch (e: UploadFailure) {
        throw e
    } catch (e: Exception) {
        throw UploadFailure.Unreadable(uri.lastPathSegment ?: uri.toString())
    }
}
