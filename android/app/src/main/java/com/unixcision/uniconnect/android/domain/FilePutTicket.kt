package com.unixcision.uniconnect.android.domain

/** What `mobile.file.begin` answers: the id the chunks quote and how many raw bytes each carries. */
data class FilePutTicket(val transferID: String, val chunkBytes: Int)
