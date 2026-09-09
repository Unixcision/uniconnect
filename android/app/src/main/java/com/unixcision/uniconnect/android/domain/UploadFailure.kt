package com.unixcision.uniconnect.android.domain

/**
 * Why an upload did not end in a link. Typed so the screen can say it in the reader's words
 * with the domain or file name in the sentence, without the transport leaking into the UI.
 */
sealed class UploadFailure(message: String) : Exception(message) {
    /** The host did not answer at all: no connection, a dropped one, or a timeout. */
    class Unreachable(val domain: String) : UploadFailure("cannot reach $domain")

    /** The host answered with an HTTP error status. */
    class Rejected(val domain: String, val code: Int) : UploadFailure("$domain answered $code")

    /** The host answered success but nothing in the body looked like a link. */
    class NoLink(val domain: String) : UploadFailure("$domain returned no link")

    /** The file could not be opened or read to the end on the phone. */
    class Unreadable(val name: String) : UploadFailure("cannot read $name")
}
