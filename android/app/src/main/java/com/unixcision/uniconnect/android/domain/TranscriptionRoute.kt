package com.unixcision.uniconnect.android.domain

/**
 * Who turns a recording into text, and what the reader is told about it.
 *
 * Pure: the decision depends only on the setting, on what each machine announces and answers, on
 * whether a Whisper model is downloaded, and on whether the phone has a recogniser, so it is made
 * the same way from every entry point and tested without a microphone, a socket or a model.
 *
 * [machine] is the one that transcribes when [engine] is `HOST`, and [ofWindow] says whether that
 * is the machine the open window lives on.
 */
data class TranscriptionRoute(
    val engine: TranscriptionEngine,
    val machine: Machine? = null,
    val ofWindow: Boolean = false,
    val notice: TranscriptionNotice? = null,
) {
    /** Whether a microphone is worth offering: something can turn a recording into text. */
    fun canDictate(phoneAvailable: Boolean): Boolean = when (engine) {
        TranscriptionEngine.HOST, TranscriptionEngine.LOCAL -> true
        TranscriptionEngine.PHONE -> phoneAvailable
    }

    /**
     * Where the recording goes, given the [window] that is open.
     *
     * The window's identifiers travel only when the machine that transcribes owns that window;
     * any other machine is asked for text and nothing else.
     */
    fun target(window: DictationTarget?): DictationTarget? = machine?.let {
        if (ofWindow && window != null) DictationTarget(it, window.workspaceID, window.terminalID)
        else DictationTarget(it)
    }

    companion object {
        /**
         * The route for [mode] against every saved machine and what the phone itself can do.
         *
         * - Parameter machines: the saved machines in the reader's own order, with what each
         *   announces and whether it is answering.
         * - Parameter windowMachineID: the machine of the open window, or null without one.
         * - Parameter chosenMachineID: the machine picked for [TranscriptionMode.MACHINE].
         * - Parameter phoneAvailable: whether the phone's system recogniser exists at all.
         * - Parameter localReady: whether Whisper can run here: the native engine loads and a
         *   model is downloaded. Both, because either alone transcribes nothing.
         * - Parameter refused: machines that answered `unsupported`, which are not asked again.
         */
        fun decide(
            mode: TranscriptionMode,
            machines: List<TranscriptionCandidate>,
            windowMachineID: String?,
            chosenMachineID: String? = null,
            phoneAvailable: Boolean = true,
            localReady: Boolean = false,
            refused: Set<String> = emptySet(),
        ): TranscriptionRoute {
            val window = machines.firstOrNull { it.machine.id == windowMachineID }?.takeIf { it.canRun(refused) }
            return when (mode) {
                TranscriptionMode.PHONE -> TranscriptionRoute(TranscriptionEngine.PHONE)
                TranscriptionMode.LOCAL ->
                    if (localReady) TranscriptionRoute(TranscriptionEngine.LOCAL)
                    else automatic(machines, window, phoneAvailable, localReady = false, refused)
                        .copy(notice = TranscriptionNotice.LOCAL_UNAVAILABLE)
                TranscriptionMode.MACHINE -> {
                    val chosen = machines.firstOrNull { it.machine.id == chosenMachineID }?.takeIf { it.canRun(refused) }
                    if (chosen != null) TranscriptionRoute(TranscriptionEngine.HOST, chosen.machine, ofWindow = chosen.machine.id == windowMachineID)
                    else automatic(machines, window, phoneAvailable, localReady, refused).copy(notice = TranscriptionNotice.CHOSEN_UNAVAILABLE)
                }
                TranscriptionMode.AUTO -> automatic(machines, window, phoneAvailable, localReady, refused)
            }
        }

        /**
         * The best there is: the window's own machine, then any other machine that can, then
         * Whisper on this phone, then the system recogniser.
         *
         * A machine comes before the phone's own Whisper because a laptop reads a minute of speech
         * in a second and a phone takes far longer; the phone's Whisper comes before the system
         * recogniser because it understands whole sentences and the recogniser does not.
         */
        private fun automatic(
            machines: List<TranscriptionCandidate>,
            window: TranscriptionCandidate?,
            phoneAvailable: Boolean,
            localReady: Boolean,
            refused: Set<String>,
        ): TranscriptionRoute {
            if (window != null) return TranscriptionRoute(TranscriptionEngine.HOST, window.machine, ofWindow = true)
            val other = machines.firstOrNull { it.canRun(refused) }
            if (other != null) return TranscriptionRoute(TranscriptionEngine.HOST, other.machine, ofWindow = false)
            if (localReady) return TranscriptionRoute(TranscriptionEngine.LOCAL)
            return TranscriptionRoute(TranscriptionEngine.PHONE, notice = TranscriptionNotice.HOST_CANNOT.takeIf { phoneAvailable })
        }

        /** Ready, and not one that already answered that it has no engine. */
        private fun TranscriptionCandidate.canRun(refused: Set<String>): Boolean = ready && machine.id !in refused
    }
}
