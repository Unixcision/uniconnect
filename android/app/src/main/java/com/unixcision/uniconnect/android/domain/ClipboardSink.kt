package com.unixcision.uniconnect.android.domain

/**
 * Dónde acaba lo que un programa remoto copia.
 *
 * Es una interfaz para que el modelo no dependa de Android y se pueda probar: la app real pone el
 * texto en el portapapeles del sistema; un test comprueba qué llegó.
 */
fun interface ClipboardSink {
    /** Deja [text] en el portapapeles. Nunca lanza: copiar no puede tumbar una conexión. */
    fun copy(text: String)
}
