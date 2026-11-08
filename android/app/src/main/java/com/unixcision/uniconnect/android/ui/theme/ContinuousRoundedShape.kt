package com.unixcision.uniconnect.android.ui.theme

import androidx.compose.runtime.Immutable
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp

/**
 * A rounded rectangle with continuous corners, the ones Apple draws everywhere.
 *
 * A plain rounded corner is a quarter circle glued to a straight edge, and the eye sees the seam
 * where the curvature jumps from nothing to the full circle. A continuous corner eases into the
 * curve over about one and a half radii, so the shape reads as one smooth object. The curves are
 * the coefficients PaintCode measured from UIKit's `cornerCurve = .continuous`.
 *
 * Each corner takes its own radius (a sheet rounds only the top). A radius larger than the shape
 * allows is reduced so the easing still fits, which also keeps a small chip from turning into a
 * pill.
 */
@Immutable
class ContinuousRoundedShape(
    private val topStart: Dp,
    private val topEnd: Dp = topStart,
    private val bottomEnd: Dp = topStart,
    private val bottomStart: Dp = topStart,
) : Shape {
    override fun createOutline(size: Size, layoutDirection: LayoutDirection, density: Density): Outline {
        val limit = minOf(size.width, size.height) / 2f / EASE
        fun px(radius: Dp) = with(density) { radius.toPx() }.coerceIn(0f, limit)
        val ltr = layoutDirection == LayoutDirection.Ltr
        val tl = px(if (ltr) topStart else topEnd)
        val tr = px(if (ltr) topEnd else topStart)
        val br = px(if (ltr) bottomEnd else bottomStart)
        val bl = px(if (ltr) bottomStart else bottomEnd)
        val w = size.width
        val h = size.height
        val path = Path().apply {
            moveTo(tl * EASE, 0f)
            // Top edge and top-right corner.
            lineTo(w - tr * EASE, 0f)
            if (tr > 0f) {
                cubicTo(w - tr * C1, 0f, w - tr * C2, 0f, w - tr * C3, tr * C4)
                cubicTo(w - tr * C5, tr * C6, w - tr * C6, tr * C5, w - tr * C4, tr * C3)
                cubicTo(w, tr * C2, w, tr * C1, w, tr * EASE)
            }
            // Right edge and bottom-right corner.
            lineTo(w, h - br * EASE)
            if (br > 0f) {
                cubicTo(w, h - br * C1, w, h - br * C2, w - br * C4, h - br * C3)
                cubicTo(w - br * C6, h - br * C5, w - br * C5, h - br * C6, w - br * C3, h - br * C4)
                cubicTo(w - br * C2, h, w - br * C1, h, w - br * EASE, h)
            }
            // Bottom edge and bottom-left corner.
            lineTo(bl * EASE, h)
            if (bl > 0f) {
                cubicTo(bl * C1, h, bl * C2, h, bl * C3, h - bl * C4)
                cubicTo(bl * C5, h - bl * C6, bl * C6, h - bl * C5, bl * C4, h - bl * C3)
                cubicTo(0f, h - bl * C2, 0f, h - bl * C1, 0f, h - bl * EASE)
            }
            // Left edge and top-left corner.
            lineTo(0f, tl * EASE)
            if (tl > 0f) {
                cubicTo(0f, tl * C1, 0f, tl * C2, tl * C4, tl * C3)
                cubicTo(tl * C6, tl * C5, tl * C5, tl * C6, tl * C3, tl * C4)
                cubicTo(tl * C2, 0f, tl * C1, 0f, tl * EASE, 0f)
            }
            close()
        }
        return Outline.Generic(path)
    }

    override fun equals(other: Any?): Boolean =
        other is ContinuousRoundedShape && topStart == other.topStart && topEnd == other.topEnd &&
            bottomEnd == other.bottomEnd && bottomStart == other.bottomStart

    override fun hashCode(): Int = ((topStart.hashCode() * 31 + topEnd.hashCode()) * 31 + bottomEnd.hashCode()) * 31 + bottomStart.hashCode()

    private companion object {
        /** How far along each edge, in radii, the curve starts to bend. */
        const val EASE = 1.52866483f
        const val C1 = 1.08849323f
        const val C2 = 0.86840689f
        const val C3 = 0.66993427f
        const val C4 = 0.06549600f
        const val C5 = 0.37282392f
        const val C6 = 0.18120190f
    }
}

/** The same shape with only the top corners rounded, for sheets and drawers that sit on an edge. */
fun continuousTop(radius: Dp) = ContinuousRoundedShape(topStart = radius, topEnd = radius, bottomEnd = 0.dp, bottomStart = 0.dp)
