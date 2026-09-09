package com.unixcision.uniconnect.android.domain

/**
 * Finds the download link in what a transfer service answers.
 *
 * The services measured answer in three shapes: a `wget https://…` line (sendit.sh), the bare
 * URL (temp.sh, litterbox, transfer.sh) or a JSON object. A JSON answer is read through its
 * `link`, `url` or `downloadUrl` key first, wherever it sits; failing that, the first http(s)
 * URL anywhere in the body is the link. No URL means no link.
 */
object UploadLink {
    private val url = Regex("""https?://[^\s"'<>\\]+""")
    private val jsonLink = Regex(""""(?:link|url|downloadUrl)"\s*:\s*"(https?://[^"]+)"""")

    /** The link in [body], or null when nothing in it is a URL. */
    fun extract(body: String): String? {
        val text = body.trim()
        if (text.startsWith("{") || text.startsWith("[")) {
            // JSON escapes slashes as `\/`; undo that before looking for the keys.
            val plain = text.replace("\\/", "/")
            jsonLink.find(plain)?.groupValues?.get(1)?.let { return it }
            return url.find(plain)?.value?.trimEnd('.', ',', ';', ')')
        }
        return url.find(text)?.value?.trimEnd('.', ',', ';', ')')
    }
}
