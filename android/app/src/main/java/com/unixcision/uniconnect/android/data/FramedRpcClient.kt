package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.MachineEndpoint
import com.unixcision.uniconnect.android.domain.MachineFailure
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import org.json.JSONObject

/** Opens only explicitly selected tailnet endpoints; cancellation closes the owned socket. */
class FramedRpcClient(private val ioScope: CoroutineScope) {
    suspend fun open(endpoint: MachineEndpoint): FramedRpcSession =
        transportDeadline(15_000) { suspendCancellableCoroutine { continuation ->
            val socket = Socket()
            val operation = ioScope.launch(Dispatchers.IO) {
                try {
                    // MagicDNS must resolve into the tailnet too: never silently dial a public/LAN address.
                    val address = InetAddress.getAllByName(endpoint.host).firstOrNull { candidate ->
                        MachineEndpoint.parse(candidate.hostAddress.orEmpty(), endpoint.port.toString()) != null
                    } ?: throw MachineFailure.Transport()
                    socket.connect(InetSocketAddress(address, endpoint.port), 7_000)
                    socket.tcpNoDelay = true
                    socket.keepAlive = true
                    if (continuation.isActive) continuation.resume(FramedRpcSession(socket, ioScope))
                    else socket.close()
                } catch (error: Exception) {
                    runCatching { socket.close() }
                    if (continuation.isActive) continuation.resumeWithException(error)
                }
            }
            continuation.invokeOnCancellation {
                runCatching { socket.close() }
                operation.cancel()
            }
        } }

    suspend fun call(endpoint: MachineEndpoint, method: String, params: JSONObject): JSONObject =
        open(endpoint).use { it.call(method, params).value }

    companion object {
        const val MAX_FRAME_BYTES = 8 * 1024 * 1024
    }
}
