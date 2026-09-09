package com.unixcision.uniconnect.android.domain

/**
 * What to do when the phone's own recogniser gives up, decided without any of Android's types.
 *
 * A recogniser that fails before anything could have been said is not answering "I did not
 * understand you": it is refusing to start. Seen on a Pixel 8 Pro whose default recognition
 * service is the text-to-speech one, where the on-device engine has no Spanish model and aborts
 * the instant it is asked, which reached the reader as "no se ha entendido" before they had opened
 * their mouth.
 */
object RecogniserRecovery {
    /** Under this, a failure is the engine refusing rather than an answer to what was said. */
    const val IMMEDIATE_MILLIS = 1_500L

    /**
     * Whether the attempt is worth making again on the network recogniser.
     *
     * Only the on-device engine is worth leaving, only once, and only while nothing has been
     * understood yet: either it said it has no model, or it gave up so fast that it cannot have
     * listened to anything.
     */
    fun retryOnline(onDevice: Boolean, triedOnline: Boolean, heard: Boolean, elapsedMillis: Long, failure: DictationFailure): Boolean =
        onDevice && !triedOnline && !heard &&
            (failure == DictationFailure.ENGINE_UNAVAILABLE || elapsedMillis < IMMEDIATE_MILLIS)

    /**
     * Whether the failure should be worded as an engine that does not answer, instead of as words
     * that were not understood. Failures with a truthful message of their own keep it.
     */
    fun silent(heard: Boolean, elapsedMillis: Long, failure: DictationFailure): Boolean =
        !heard && elapsedMillis < IMMEDIATE_MILLIS && failure in ENGINE_SIDE

    /** The failures that mean nothing to the reader when they arrive before a word could be said. */
    private val ENGINE_SIDE = setOf(DictationFailure.NOT_UNDERSTOOD, DictationFailure.ENGINE_UNAVAILABLE, DictationFailure.OTHER)
}
