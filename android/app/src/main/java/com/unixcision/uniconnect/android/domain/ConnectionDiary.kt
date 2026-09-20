package com.unixcision.uniconnect.android.domain

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Lo que pasó con las conexiones, para poder contarlo después.
 *
 * Existe porque durante días se diagnosticaron fallos de conexión **adivinando**: la app se quedaba
 * sin poder enviar y no había forma de saber si el equipo había rechazado, si el plazo se había
 * agotado, o si el socket ni siquiera llegó a abrirse. La persona que lo sufre es la única que
 * estaba delante cuando ocurrió, así que es ella quien tiene que poder contar qué pasó.
 *
 * Sobrevive al cierre de la app a través de ``ConnectionDiary.Store``: un diagnóstico que solo vive
 * en memoria se pierde justo cuando hace falta —al cerrarla, al matarla Android, al reiniciar el
 * móvil tras el fallo—. El almacén es un seam inyectado, así que el diario sigue siendo probable
 * sin Android delante.
 */
data class ConnectionEvent(
    /** Cuándo, en milisegundos desde época. Se formatea al mostrarlo, no al guardarlo. */
    val at: Long,
    /** Qué se intentaba: `sondeo`, `abrir`, `adjuntar`, `reconectar`… */
    val stage: String,
    /** A qué equipo, por su nombre visible. */
    val machine: String,
    /** El destino tal y como está guardado, que es lo que de verdad se marcó. */
    val endpoint: String,
    /** Cómo acabó. */
    val outcome: Outcome,
    /** Cuánto tardó en acabar así. Un fallo rápido y uno lento no tienen la misma causa. */
    val millis: Long,
    /** El detalle exacto: código del equipo, o la excepción del transporte. Nunca inventado. */
    val detail: String? = null,
    /** Qué red había en ese momento: `wifi`, `móvil`, `sin red`. */
    val network: String? = null,
) {
    enum class Outcome { OK, RECHAZADO, PLAZO_AGOTADO, ERROR_TRANSPORTE, CANCELADO }
}

/**
 * Un diario acotado de los últimos intentos.
 *
 * Acotado porque un registro que crece sin fin acaba siendo un problema por sí mismo: llena el
 * disco del móvil y nadie lo lee entero. Lo último es lo que explica el fallo que se acaba de ver.
 */
class ConnectionDiary(
    private val capacity: Int = 200,
    /** Dónde sobrevive al cierre. `null` = solo en memoria (tests, previsualizaciones). */
    private val store: Store? = null,
) {
    /** Persistencia del diario. La implementación de Android escribe un fichero en la app. */
    interface Store {
        /** Lo que quedó de la última vez. Una lectura que falle devuelve lista vacía, nunca revienta. */
        fun load(): List<ConnectionEvent>

        /** Guarda el diario entero. Se llama en cada apunte: son pocos y pequeños. */
        fun save(events: List<ConnectionEvent>)
    }

    private val events = ArrayDeque(store?.load().orEmpty().takeLast(capacity))
    private val revisions = MutableStateFlow(0)

    /**
     * Cambia cada vez que se apunta algo.
     *
     * Existe porque la interfaz preguntaba por ``worthReporting`` con una llamada normal dentro de
     * la composición: Compose no observa una llamada a función, así que el botón de diagnóstico
     * **nunca se redibujaba** cuando aparecían los fallos. Con esto la pantalla se entera.
     */
    val changes: StateFlow<Int> = revisions.asStateFlow()

    /** Apunta un intento. El más viejo cae cuando no cabe.  */
    @Synchronized
    fun record(event: ConnectionEvent) {
        events.addLast(event)
        while (events.size > capacity) events.removeFirst()
        store?.save(events.toList())
        revisions.value += 1
    }

    /** Todo lo apuntado, del más antiguo al más reciente. */
    @Synchronized
    fun all(): List<ConnectionEvent> = events.toList()

    /** Solo lo que salió mal, que es por donde se empieza a mirar. */
    @Synchronized
    fun failures(): List<ConnectionEvent> =
        events.filter { it.outcome != ConnectionEvent.Outcome.OK }

    @Synchronized
    fun clear() {
        events.clear()
        store?.save(emptyList())
        revisions.value += 1
    }

    /**
     * Si conviene ofrecer el diagnóstico sin que lo pidan.
     *
     * Un fallo suelto es ruido —una reconexión normal produce alguno—; varios seguidos son una
     * historia. El botón aparece cuando hay algo que contar, no cada vez que parpadea la red.
     *
     * Esto decide el botón **de la lista de equipos**. Dentro de un terminal caído el botón no
     * espera a ningún umbral: ahí el fallo ya está en pantalla, y hacer que el diagnóstico dependa
     * de acumular tres es exactamente lo que dejó a la persona mirando un error sin poder contarlo.
     */
    @Synchronized
    fun worthReporting(recent: Int = 5, threshold: Int = 3): Boolean =
        events.takeLast(recent).count { it.outcome != ConnectionEvent.Outcome.OK } >= threshold
}
