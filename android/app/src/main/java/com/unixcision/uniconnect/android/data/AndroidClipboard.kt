package com.unixcision.uniconnect.android.data

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Handler
import android.os.Looper
import com.unixcision.uniconnect.android.domain.ClipboardSink

/**
 * El portapapeles del teléfono.
 *
 * Se escribe en el hilo principal porque `ClipboardManager` lo exige en algunas versiones, y lo
 * copiado llega desde el lector del PTY. Android 13+ ya enseña su propio aviso de «copiado», así
 * que aquí no se añade otro.
 */
class AndroidClipboard(private val context: Context) : ClipboardSink {
    private val main = Handler(Looper.getMainLooper())

    override fun copy(text: String) {
        main.post {
            runCatching {
                val manager = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager ?: return@runCatching
                manager.setPrimaryClip(ClipData.newPlainText("UniConnect", text))
            }
        }
    }
}
