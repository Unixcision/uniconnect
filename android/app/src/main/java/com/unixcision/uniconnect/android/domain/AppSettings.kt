package com.unixcision.uniconnect.android.domain

/**
 * The preferences that change how the app behaves, with the defaults it ships with.
 *
 * - Parameter terminalView: how a terminal is laid out when a window is opened.
 * - Parameter showExtraKeys: whether the control key row starts open.
 * - Parameter probeOnOpen: whether the list asks every machine if it answers, without being asked.
 * - Parameter designTheme: which of the four designs dresses the app.
 * - Parameter colorMode: whether that design is shown light, dark or as the phone is set.
 * - Parameter uploadService: where "Enviar archivos" sends files and how.
 * - Parameter terminalUploadService: where the terminal's clip sends a file when the host cannot
 *   take it directly; null means "the same as Enviar archivos", which is the default.
 * - Parameter sendOnDictationEnd: whether dictated text is sent with Enter as soon as dictation
 *   ends, instead of waiting in the composer for the reader to send it.
 * - Parameter dictationLanguage: the language dictation is recognised in.
 * - Parameter transcription: whether dictated audio is turned into text by the machine, which is
 *   better at it, or by the phone itself.
 */
data class AppSettings(
    val terminalView: TerminalView = TerminalView.PAN,
    val showExtraKeys: Boolean = false,
    val probeOnOpen: Boolean = true,
    val designTheme: DesignTheme = DesignTheme.SERENO,
    val colorMode: ColorMode = ColorMode.SYSTEM,
    val uploadService: UploadService = UploadService.default,
    val terminalUploadService: UploadService? = null,
    val sendOnDictationEnd: Boolean = false,
    val dictationLanguage: DictationLanguage = DictationLanguage.DEVICE,
    val transcription: TranscriptionMode = TranscriptionMode.AUTO,
) {
    /** The fallback service the terminal's clip actually uses: its own choice, or the one of "Enviar archivos". */
    val terminalUpload: UploadService get() = terminalUploadService ?: uploadService
}
