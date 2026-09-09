package com.unixcision.uniconnect.android.domain

/**
 * Whether the chosen [DesignTheme] is shown in its light or dark palette. [SYSTEM] follows the
 * phone's own setting, so the app flips with it without being reopened.
 */
enum class ColorMode {
    LIGHT,
    DARK,
    SYSTEM;

    companion object {
        /** Reads a stored name, falling back to [SYSTEM] for anything unrecognised. */
        fun named(raw: String?): ColorMode = entries.firstOrNull { it.name == raw } ?: SYSTEM
    }
}
