package com.unixcision.uniconnect.android.notifications

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import androidx.compose.ui.graphics.toArgb
import com.unixcision.uniconnect.android.ui.components.boxTone
import com.unixcision.uniconnect.android.ui.components.monogram

/**
 * The workspace's two-letter monogram as a notification icon: same letters and same colour the
 * list uses, so a notice is recognised at a glance. Only notices get it; the connection
 * notification keeps the app's own logo.
 */
object NoticeMonogram {
    fun bitmap(context: Context, workspaceName: String): Bitmap {
        val size = (64 * context.resources.displayMetrics.density).toInt().coerceAtLeast(96)
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val radius = size * 0.28f
        canvas.drawRoundRect(RectF(0f, 0f, size.toFloat(), size.toFloat()), radius, radius,
            Paint(Paint.ANTI_ALIAS_FLAG).apply { color = boxTone(workspaceName).toArgb() })
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = android.graphics.Color.WHITE
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            textSize = size * 0.42f
            textAlign = Paint.Align.CENTER
        }
        val baseline = size / 2f - (paint.descent() + paint.ascent()) / 2f
        canvas.drawText(monogram(workspaceName), size / 2f, baseline, paint)
        return bitmap
    }
}
