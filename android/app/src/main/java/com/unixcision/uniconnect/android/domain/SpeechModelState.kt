package com.unixcision.uniconnect.android.domain

/** Why a model could not be downloaded, in terms the settings sheet can word. */
enum class SpeechModelFailure {
    /** There is not enough free space on the phone for the whole file. */
    NO_SPACE,

    /** The download could not reach the server or was cut short. */
    NETWORK,

    /** What arrived is not the model: the wrong size, or not a ggml file at all. */
    CORRUPT,

    /** The file could not be written to the app's own storage. */
    WRITE_FAILED,
}

/** Where one model is, from the settings sheet's point of view. */
sealed class SpeechModelState {
    /** Not on the phone. */
    data object Missing : SpeechModelState()

    /**
     * Being fetched: [downloaded] of [total] bytes, [total] being the model's own size.
     *
     * A download that resumes starts from what was already on disk, so [downloaded] is what the
     * phone holds and not what this attempt has fetched.
     */
    data class Downloading(val downloaded: Long, val total: Long) : SpeechModelState()

    /**
     * Part of the file is on the phone and nothing is fetching it: the reader stopped the
     * download, or the app was closed during one. The next attempt carries on from [downloaded].
     */
    data class Paused(val downloaded: Long, val total: Long) : SpeechModelState()

    /** On the phone and usable, taking [bytes] of storage. */
    data class Ready(val bytes: Long) : SpeechModelState()

    /**
     * The download ended without a usable model. [downloaded] is what is still on disk and will be
     * resumed from, so a failure halfway through does not throw away what was already fetched.
     *
     * [detail] is the concrete cause in the server's or the platform's own terms — an HTTP status,
     * the name of the exception that was thrown — shown after the sentence. "Check your
     * connection" is what an app says when it has not bothered to look; the detail is what makes
     * the difference between a captive portal, a blocked host and a server that answered 403.
     */
    data class Failed(
        val reason: SpeechModelFailure,
        val downloaded: Long = 0,
        val detail: String? = null,
    ) : SpeechModelState()

    /** How far along, from 0 to 1, for the states that hold part of a file. */
    val fraction: Float
        get() = when (this) {
            is Downloading -> ratio(downloaded, total)
            is Paused -> ratio(downloaded, total)
            is Failed -> 0f
            is Ready -> 1f
            Missing -> 0f
        }

    /** Whether something is being fetched right now. */
    val busy: Boolean get() = this is Downloading

    private fun ratio(done: Long, total: Long): Float = if (total <= 0) 0f else (done.toFloat() / total).coerceIn(0f, 1f)
}
