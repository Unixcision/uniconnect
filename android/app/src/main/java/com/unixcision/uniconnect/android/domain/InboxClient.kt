package com.unixcision.uniconnect.android.domain

import java.io.File

/**
 * La bandeja de entrada de un equipo (`inbox.v1`): ver, traer y borrar lo que el móvil subió.
 *
 * Interfaz para que el modelo se pruebe sin red; la app real habla con el equipo por la conexión
 * privada (ver `NativeInboxClient`).
 */
interface InboxClient {
    suspend fun list(machine: Machine, limit: Int = 200, offset: Int = 0): InboxListing

    suspend fun delete(machine: Machine, deletion: InboxDeletion): InboxDeletionResult

    /**
     * Trae [entry] entero a [destination], por trozos, informando de lo recibido. Para la vista
     * previa de una imagen o para reproducir un vídeo o un audio en el móvil.
     */
    suspend fun download(machine: Machine, entry: InboxEntry, destination: File, progress: (Long) -> Unit = {})
}
