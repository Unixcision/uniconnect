package com.unixcision.uniconnect.android.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import com.unixcision.uniconnect.android.ui.theme.UniTheme

/**
 * Eyebrow label, in tracked small capitals where the theme asks for them, with optional trailing
 * content. A quiet theme sets it in the muted colour at normal weight instead of the accent in
 * bold, so the label names the section without competing with it.
 */
@Composable
fun SectionLabel(text: String, modifier: Modifier = Modifier, trailing: @Composable RowScope.() -> Unit = {}) {
    val spacing = UniTheme.spacing
    val quiet = UniTheme.type.labelQuiet
    Row(modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(spacing.gapSmall)) {
        Text(
            if (UniTheme.type.labelUppercase) text.uppercase() else text,
            style = if (UniTheme.type.labelUppercase) MaterialTheme.typography.labelSmall else MaterialTheme.typography.labelMedium,
            color = if (quiet) UniTheme.colors.muted else UniTheme.colors.accent,
            fontWeight = if (quiet) FontWeight.Medium else FontWeight.Bold,
        )
        Spacer(Modifier.weight(1f))
        trailing()
    }
}
