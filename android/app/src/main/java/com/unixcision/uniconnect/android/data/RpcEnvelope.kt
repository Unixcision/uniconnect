package com.unixcision.uniconnect.android.data

import org.json.JSONObject

/** The receive order gives a replay response a barrier against older buffered events. */
data class RpcEnvelope(val value: JSONObject, val ordinal: Long, val byteCount: Int)
