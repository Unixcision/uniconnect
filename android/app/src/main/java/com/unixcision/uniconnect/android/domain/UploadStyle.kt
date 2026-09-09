package com.unixcision.uniconnect.android.domain

/** How a transfer service expects to receive a file. Measured against the live services, not guessed. */
enum class UploadStyle {
    /** The file's own bytes as the request body, sent to `/<name>` with POST or PUT (sendit.sh, transfer.sh). */
    RAW_NAMED,

    /** A multipart form with one `file` field, sent to `/upload` (temp.sh). */
    MULTIPART_FILE,

    /** litterbox.catbox.moe's form: `reqtype=fileupload`, `time=72h` and `fileToUpload`, sent to its API path. */
    LITTERBOX;

    companion object {
        /** Reads a stored name, falling back to [RAW_NAMED] for anything unrecognised. */
        fun named(raw: String?): UploadStyle = entries.firstOrNull { it.name == raw } ?: RAW_NAMED
    }
}
