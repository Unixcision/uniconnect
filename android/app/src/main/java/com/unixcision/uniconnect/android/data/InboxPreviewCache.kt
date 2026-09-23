package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.InboxEntry
import java.io.File
import java.security.MessageDigest

/**
 * Las copias locales de lo que se ha mirado de la bandeja de un equipo, en la caché de la app.
 *
 * El nombre sale del equipo, la ruta, el tamaño y la fecha: si el archivo del equipo cambia, la
 * copia vieja deja de valer sola, sin comparar contenidos. Se conserva la extensión porque es lo
 * que usan el reproductor y «Abrir con…» para saber qué es. Pasado [maxBytes] se tira lo que
 * lleva más tiempo sin mirarse; Android además puede vaciar la caché cuando le haga falta.
 */
class InboxPreviewCache(private val root: File, private val maxBytes: Long = 300L * 1024 * 1024) {
    /** Dónde vive (o vivirá) la copia de [entry] de la máquina [machineID]. */
    fun fileFor(machineID: String, entry: InboxEntry): File {
        val key = sha1("$machineID\u0000${entry.path}\u0000${entry.size}\u0000${entry.modified}")
        val extension = entry.name.substringAfterLast('.', "").lowercase().filter { it.isLetterOrDigit() }.take(8)
        return File(root, if (extension.isEmpty()) key else "$key.$extension")
    }

    /** La copia completa si ya está; una a medias (tamaño distinto) no cuenta. */
    fun cached(machineID: String, entry: InboxEntry): File? =
        fileFor(machineID, entry).takeIf { it.isFile && it.length() == entry.size }?.also { it.setLastModified(System.currentTimeMillis()) }

    /** Tira lo más antiguo hasta quedar por debajo del límite; [keep] no se toca nunca. */
    fun trim(keep: File? = null) {
        val files = root.listFiles()?.filter { it.isFile && !it.name.endsWith(".part") } ?: return
        var total = files.sumOf { it.length() }
        for (file in files.sortedBy { it.lastModified() }) {
            if (total <= maxBytes) break
            if (file == keep) continue
            val size = file.length()
            if (file.delete()) total -= size
        }
    }

    /** Vacía todas las copias: tras liberar espacio en un equipo, las suyas ya no se van a pedir. */
    fun clear() {
        root.listFiles()?.forEach { it.delete() }
    }

    private fun sha1(text: String): String =
        MessageDigest.getInstance("SHA-1").digest(text.toByteArray()).joinToString("") { "%02x".format(it) }
}
