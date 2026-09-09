package com.unixcision.uniconnect.android.ui.theme

import androidx.compose.runtime.Immutable
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.TextUnit

/**
 * The type choices of one theme.
 *
 * - [headlineFamily] dresses display, headline and title styles.
 * - [identifierFamily] dresses names of machines, boxes and windows, and addresses.
 * - [labelUppercase] says whether eyebrow labels and metadata are set in small capitals, and
 *   [labelLetterSpacing] how much they are tracked.
 */
@Immutable
data class UniType(
    val headlineFamily: FontFamily,
    val identifierFamily: FontFamily,
    val labelUppercase: Boolean,
    val labelLetterSpacing: TextUnit,
)
