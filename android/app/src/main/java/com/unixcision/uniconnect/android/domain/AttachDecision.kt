package com.unixcision.uniconnect.android.domain

/**
 * What happens with a file when the picker returns, given the route captured when the reader
 * tapped and what the host announces now. The reader always knows where a file goes before
 * choosing it, so a route never changes behind their back: a host that stopped taking files
 * while the picker was open makes the attachment fail instead of sending it elsewhere.
 */
sealed class AttachDecision {
    /** Send by the captured route. */
    data class Send(val route: AttachRoute) : AttachDecision()

    /** The captured route was the host, and the host no longer takes files: fail, do not go external. */
    data object HostLostCapability : AttachDecision()

    companion object {
        /** The decision for a file picked under [captured] when the host [takesFilesNow] or not. */
        fun onReturn(captured: AttachRoute, takesFilesNow: Boolean): AttachDecision =
            if (captured == AttachRoute.HOST && !takesFilesNow) HostLostCapability else Send(captured)
    }
}

/** The failure a transfer carries when [AttachDecision.HostLostCapability] was the decision. */
class HostLostCapability : Exception("the host no longer announces file_put.v1")
