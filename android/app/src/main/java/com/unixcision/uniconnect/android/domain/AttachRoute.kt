package com.unixcision.uniconnect.android.domain

/** Where an attachment picked from a terminal window goes. */
enum class AttachRoute {
    /** The window's host, over the private connection (`file_put.v1`). */
    HOST,

    /** The fallback transfer service chosen in the settings, outside the reader's machines. */
    EXTERNAL;

    companion object {
        /**
         * The route for a window whose host [takesFiles] or not. A host that takes files always
         * gets the file over the private connection; otherwise the sheet says so on screen and
         * the file goes to the fallback service with the same single tap.
         */
        fun forHost(takesFiles: Boolean): AttachRoute = if (takesFiles) HOST else EXTERNAL
    }
}
