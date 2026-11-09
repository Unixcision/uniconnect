package com.unixcision.uniconnect.android.domain

/**
 * Lo que alguien pidió: qué verbo, a qué alcance de cada equipo y con qué opciones.
 *
 * «Todo» no existe en el protocolo: es una petición con un alcance `machine` por cada equipo
 * conectado que lo anuncia ([everywhere]). Así un equipo que no contesta se ve como un equipo que
 * no contesta, en vez de desaparecer dentro del total de otro.
 */
data class RelaunchRequest(
    val verb: RelaunchVerb,
    val scopes: List<RelaunchScope>,
    val options: RelaunchOptions = RelaunchOptions(),
    /** Pedido para todos los equipos a la vez: siempre se pregunta antes, aunque sea uno. */
    val everywhere: Boolean = false,
) {
    init {
        // Relanzar no cambia nada: unas opciones con agent.relaunch serían opciones_no_validas.
        require(verb == RelaunchVerb.UPDATE || options.isEmpty)
    }

    /** Lo que viaja en `options`: solo con `agent.update` y si se pide algún cambio. */
    val wireOptions: RelaunchOptions? get() = options.takeIf { verb == RelaunchVerb.UPDATE && !it.isEmpty }
}
