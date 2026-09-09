package com.unixcision.uniconnect.android.domain

/**
 * One finished upload: the [link] the service gave back for a file called [name] of [size]
 * bytes, and when it was sent as epoch milliseconds. Kept in the history so a link can be copied
 * again after the app was closed.
 */
data class UploadResult(
    val link: String,
    val name: String,
    val size: Long,
    val uploadedAt: Long,
)
