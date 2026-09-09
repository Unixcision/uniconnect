package com.unixcision.uniconnect.android.domain

import java.net.URLEncoder

/**
 * Where files are sent: a [domain] and the [style] it speaks. The shipped [presets] cover the
 * services measured today; any other domain is a custom service with a chosen style, because
 * these services go down and the reader must be able to move without a new build.
 *
 * A [domain] is normally bare (`sendit.sh`) and is spoken to over https. A domain that carries
 * its own scheme is used as typed, which is what a test against a local server needs.
 */
data class UploadService(val domain: String, val style: UploadStyle) {
    /** The root requests go to: the domain with its scheme, https unless one was given. */
    val baseUrl: String
        get() = if ("://" in domain) domain.trimEnd('/') else "https://${domain.trimEnd('/')}"

    /** Whether this is one of the shipped services rather than one the reader typed. */
    val isPreset: Boolean get() = this in presets

    /** The URL a file called [name] is sent to, as [style] dictates. */
    fun uploadUrl(name: String): String = when (style) {
        UploadStyle.RAW_NAMED -> "$baseUrl/${URLEncoder.encode(name, "UTF-8").replace("+", "%20")}"
        UploadStyle.MULTIPART_FILE -> "$baseUrl/upload"
        UploadStyle.LITTERBOX -> "$baseUrl/resources/internals/api.php"
    }

    companion object {
        /** The services measured today, first one first: sendit.sh is the default. */
        val presets: List<UploadService> = listOf(
            UploadService("sendit.sh", UploadStyle.RAW_NAMED),
            UploadService("temp.sh", UploadStyle.MULTIPART_FILE),
            UploadService("litterbox.catbox.moe", UploadStyle.LITTERBOX),
            UploadService("transfer.sh", UploadStyle.RAW_NAMED),
        )

        /** What the app ships with. */
        val default: UploadService get() = presets.first()

        /**
         * Cleans what a reader typed as a domain: spaces and an `https://` prefix are dropped, a
         * path is cut off, the case is folded. An explicit `http://` is kept so a home server on
         * plain http can be named, though the phone refuses cleartext unless it allows it.
         */
        fun normalizeDomain(raw: String): String {
            val trimmed = raw.trim().lowercase()
            val insecure = trimmed.startsWith("http://")
            val host = trimmed.removePrefix("http://").removePrefix("https://").substringBefore('/').trim()
            return if (insecure && host.isNotEmpty()) "http://$host" else host
        }
    }
}
