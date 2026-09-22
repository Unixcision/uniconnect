package com.unixcision.uniconnect.android.domain

/**
 * Decide si hay que pedirle al equipo la pantalla del espejo.
 *
 * Existe porque pedirla cuando no se mira no es solo gasto: **tira la conexión**. El equipo emite
 * `terminal.render_grid` a quien se suscriba, y la cola de eventos del móvil está acotada; si nadie
 * la vacía —porque la pantalla que se está viendo es el terminal real, que tiene su propio canal—
 * se llena en menos de un segundo y el transporte entero muere con `EventBufferOverflow`. Luego
 * reconecta, vuelve a adjuntar, y otra vez. En un informe real: 160 fallos de 200 intentos, igual
 * por wifi que por datos, o sea que nunca fue la red.
 *
 * Vive aquí, separado del modelo, porque es una decisión y se puede probar sin Android delante.
 */
object MirrorSubscription {
    /**
     * La ventana cuyo espejo hay que seguir, o `null` para seguir solo el árbol.
     *
     * - Parameters:
     *   - workspaceID: el espacio abierto, si hay alguno.
     *   - windowID: la ventana abierta, si hay alguna.
     *   - realTerminalActive: si el terminal real ya está adjuntado y trayendo la pantalla por su
     *     cuenta. Cuando lo está, el espejo sobra **y hace daño**.
     */
    fun target(workspaceID: String?, windowID: String?, realTerminalActive: Boolean): TerminalTarget? {
        if (realTerminalActive) return null
        if (workspaceID == null || windowID == null) return null
        return TerminalTarget(workspaceID, windowID)
    }
}
