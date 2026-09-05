package com.unixcision.uniconnect.android.domain

/** Special keys the on-screen keyboard bar can send; plain text never goes through this type. */
enum class TerminalKey {
    ESCAPE, TAB, ENTER, BACKSPACE, DELETE, INSERT,
    UP, DOWN, LEFT, RIGHT, HOME, END, PAGE_UP, PAGE_DOWN,
    F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12;

    val isFunctionKey: Boolean get() = ordinal >= F1.ordinal
    val functionNumber: Int get() = if (isFunctionKey) ordinal - F1.ordinal + 1 else 0
}

/** Sticky modifiers chosen on screen; they are combined with the next key or text exactly once. */
data class TerminalModifiers(val ctrl: Boolean = false, val alt: Boolean = false, val shift: Boolean = false) {
    val isEmpty: Boolean get() = !ctrl && !alt && !shift

    /** xterm's `CSI 1;m` parameter: 1 plus shift=1, alt=2, ctrl=4; null when nothing is held. */
    val xtermParameter: Int? get() = if (isEmpty) null else 1 + (if (shift) 1 else 0) + (if (alt) 2 else 0) + (if (ctrl) 4 else 0)

    companion object { val NONE = TerminalModifiers() }
}
