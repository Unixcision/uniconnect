package com.unixcision.uniconnect.android.domain

import java.net.URLEncoder

/**
 * Where files are sent: a [domain] and the [style] it speaks. The shipped [presets] cover the
 * services measured today; any other domain is a custom service with a chosen style, because
 * these services go down and the reader must be able to move without a new build.
 *
 * A [domain] is normally bare (`sendit.sh`) and is spoken to over https. A domain that carries
 * its own scheme is used as typed, which is what a test against a local server needs; one that
 * also carries a path (`https://mi.servidor.com/api/upload`) names the endpoint itself: a form
 * style posts to it as typed and the raw style appends the file name to it.
 */
data class UploadService(val domain: String, val style: UploadStyle) {
    /** The root requests go to: the domain with its scheme, https unless one was given. */
    val baseUrl: String
        get() = if ("://" in domain) domain.trimEnd('/') else "https://${domain.trimEnd('/')}"

    /** Whether [domain] is a full URL that names its own path, so the default paths of a style do not apply. */
    val hasOwnPath: Boolean
        get() = "://" in domain && domain.substringAfter("://").substringAfter('/', "").trim('/').isNotEmpty()

    /** Whether this is one of the shipped services rather than one the reader typed. */
    val isPreset: Boolean get() = this in presets

    /** The URL a file called [name] is sent to, as [style] dictates. */
    fun uploadUrl(name: String): String = when (style) {
        UploadStyle.RAW_NAMED -> "$baseUrl/${URLEncoder.encode(name, "UTF-8").replace("+", "%20")}"
        UploadStyle.MULTIPART_FILE -> if (hasOwnPath) baseUrl else "$baseUrl/upload"
        UploadStyle.LITTERBOX -> if (hasOwnPath) baseUrl else "$baseUrl/resources/internals/api.php"
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

        /**
         * Cleans what a reader typed as a full URL: scheme, host, port and path are kept as typed
         * (spaces dropped, host folded, trailing slash trimmed); a bare domain goes through
         * [normalizeDomain]. Empty when nothing usable was typed or the scheme is not http(s).
         */
        fun normalizeUrl(raw: String): String {
            val trimmed = raw.trim()
            if ("://" !in trimmed) return normalizeDomain(trimmed)
            val scheme = trimmed.substringBefore("://").lowercase()
            if (scheme != "http" && scheme != "https") return ""
            val rest = trimmed.substringAfter("://").replace(Regex("\\s+"), "")
            val host = rest.substringBefore('/').lowercase()
            if (host.isEmpty()) return ""
            val path = rest.substringAfter('/', "").trim('/')
            return if (path.isEmpty()) "$scheme://$host" else "$scheme://$host/$path"
        }
    }
}
