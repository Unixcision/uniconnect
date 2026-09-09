package com.unixcision.uniconnect.android.ui.components

import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.BackHand
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.Icon
import androidx.compose.material3.LoadingIndicator
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.ActivityState
import com.unixcision.uniconnect.android.ui.Brand

/**
 * The one mark for what an AI is doing: a small live indicator while it works, a raised hand in
 * amber when it waits for the reader. Nothing for idle or unknown, so a quiet list stays quiet.
 */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun ActivityMark(state: ActivityState, modifier: Modifier = Modifier, size: Dp = 18.dp, tone: Color = Brand.Cyan) {
    when (state) {
        ActivityState.WORKING -> LoadingIndicator(modifier.size(size), color = tone)
        ActivityState.WAITING -> Icon(Icons.Rounded.BackHand, stringResource(R.string.activity_waiting), modifier.size(size), tint = Brand.Amber)
        ActivityState.IDLE, ActivityState.UNKNOWN -> {}
    }
}
