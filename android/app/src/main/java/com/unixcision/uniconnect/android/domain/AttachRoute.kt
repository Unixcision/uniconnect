package com.unixcision.uniconnect.android.domain

/** Where an attachment picked from a terminal window goes. */
enum class AttachRoute {
    /** The window's host, over the private connection (`file_put.v1`). */
    HOST,

    /** The transfer service of "Enviar archivos", outside the reader's machines. */
    EXTERNAL;

    companion object {
        /**
         * The route for a window whose host [takesFiles] or not, given whether the reader has
         * [chosenExternal] with the explicit button. A host that takes files always gets the
         * file; without that, nothing leaves the phone unless the reader chose the external
         * service themselves: the answer is then null and no transfer is started.
         */
        fun decide(takesFiles: Boolean, chosenExternal: Boolean): AttachRoute? = when {
            takesFiles -> HOST
            chosenExternal -> EXTERNAL
            else -> null
        }
    }
}
