package com.unixcision.uniconnect.android.ui.theme

import androidx.compose.runtime.Immutable
import androidx.compose.ui.text.font.FontFamily

/**
 * The type choices of one theme.
 *
 * - [headlineFamily] dresses display, headline and title styles.
 * - [identifierFamily] dresses names of machines, boxes and windows, and addresses.
 * - [labelUppercase] says whether eyebrow labels are set in small capitals.
 */
@Immutable
data class UniType(
    val headlineFamily: FontFamily,
    val identifierFamily: FontFamily,
    val labelUppercase: Boolean,
)
