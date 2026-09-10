package com.unixcision.uniconnect.android.ui.components

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.BackHand
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.ActivityState
import com.unixcision.uniconnect.android.ui.theme.UniTheme

/**
 * The one mark for what an AI is doing: a small spinner while it works, a raised hand in the
 * warning colour when it waits for the reader. Nothing for idle or unknown, so a quiet list
 * stays quiet.
 */
@Composable
fun ActivityMark(state: ActivityState, modifier: Modifier = Modifier, size: Dp = 18.dp, tone: Color = UniTheme.colors.accent) {
    when (state) {
        ActivityState.WORKING -> WorkingSpinner(modifier, size, tone)
        ActivityState.WAITING -> Icon(Icons.Rounded.BackHand, stringResource(R.string.activity_waiting), modifier.size(size), tint = UniTheme.colors.warning)
        ActivityState.IDLE, ActivityState.UNKNOWN -> {}
    }
}

/**
 * An arc that turns. The arc is drawn once and only the layer's rotation changes, so a frame costs
 * one transform on one render node.
 *
 * This is the whole reason the mark is hand-drawn instead of Material's `LoadingIndicator`: a
 * working agent can stay working for hours, and an indicator that redraws its own shape every
 * frame kept the entire window re-rendering at the display's refresh rate for all that time —
 * ~120 fps and three quarters of a core on a Pixel 8 Pro, with a warm phone to match. Asking for a
 * lower frame rate did not help, because the cost was the redraw, not the rate.
 */
@Composable
private fun WorkingSpinner(modifier: Modifier, size: Dp, tone: Color) {
    val transition = rememberInfiniteTransition(label = "activity-spin")
    val turn = transition.animateFloat(
        initialValue = 0f,
        targetValue = 360f,
        animationSpec = infiniteRepeatable(tween(TURN_MILLIS, easing = LinearEasing)),
        label = "activity-turn",
    )
    Canvas(modifier.size(size).graphicsLayer { rotationZ = turn.value }) {
        val stroke = this.size.minDimension * STROKE_FRACTION
        drawArc(
            color = tone,
            startAngle = 0f,
            sweepAngle = SWEEP_DEGREES,
            useCenter = false,
            topLeft = androidx.compose.ui.geometry.Offset(stroke / 2f, stroke / 2f),
            size = androidx.compose.ui.geometry.Size(this.size.width - stroke, this.size.height - stroke),
            style = Stroke(width = stroke, cap = androidx.compose.ui.graphics.StrokeCap.Round),
        )
    }
}

/** One full turn of the working mark. */
private const val TURN_MILLIS = 1100
/** How much of the circle the arc covers; the gap is what makes the turn readable. */
private const val SWEEP_DEGREES = 280f
/** Stroke width as a fraction of the mark's size. */
private const val STROKE_FRACTION = .16f
