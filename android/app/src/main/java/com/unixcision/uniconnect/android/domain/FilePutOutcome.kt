package com.unixcision.uniconnect.android.domain

/** Where a committed file ended up. */
enum class FilePutLocation { HOST, REMOTE }

/**
 * What `mobile.file.commit` answers. [path] is always the file on the host; when the box is an
 * SSH one the host copies it on and gives [remotePath] with [location] `REMOTE`, or keeps the
 * host copy and explains in [remoteError] why the copy did not happen.
 */
data class FilePutOutcome(
    val path: String,
    val location: FilePutLocation,
    val remotePath: String? = null,
    val remoteError: String? = null,
) {
    /** The path worth pasting into the composer: the remote one when the file got there, else the host's. */
    val pastePath: String get() = if (location == FilePutLocation.REMOTE && !remotePath.isNullOrEmpty()) remotePath else path
}
