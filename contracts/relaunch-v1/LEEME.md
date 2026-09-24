# Ejemplos normativos de `relaunch.v1`

Estos archivos **son el contrato**, no una ilustración. Las pruebas de Mac, Linux y Android leen
estos mismos ficheros; si un ejemplo y una implementación discrepan, manda el ejemplo.

El documento que los explica es `docs/RELANZAR-v1.md`.

| Archivo | Qué fija |
|---|---|
| `plan-request.json` | Forma de `relaunch.plan`. |
| `plan-response.json` | Objetivos, exclusiones con causa, token y caducidad. |
| `apply-request.json` | Forma de `relaunch.apply`. |
| `apply-response.json` | Resultado por objetivo de un `apply` que sí ejecutó. |
| `apply-recovered-response.json` | Un `apply` repetido de una operación ya aceptada: `recovered: true`, no se ejecuta nada nuevo, y vale aunque el token haya caducado. |
| `apply-in-progress-response.json` | `apply` no bloquea hasta terminar: devuelve con `operation_state: "en_curso"` y el cliente sigue con `relaunch.status`. |
| `status-request.json` | Forma de `relaunch.status`. |
| `errors.json` | Errores de la llamada, distintos de las causas por objetivo. |
| `causes.json` | Causas estables por objetivo. El texto en español lo pone el cliente. |

## Quién lee qué (a 24-09-2026)

Solo lo que existe en el repositorio. Afirmar una lectura que no ocurre es peor que no apuntarla:
da por vigilado un fichero que nadie mira.

| Archivo | Lo lee hoy |
|---|---|
| `causes.json` | Android: `RelaunchTest` exige que `RelaunchCause` sea exactamente este conjunto. Mac: `RelaunchCauseCatalogueTests` lo pretende, pero sube cuatro carpetas desde su fichero y lo busca en `Packages/contracts/…`, que no existe; al no encontrarlo sale sin comparar nada. Hasta que se corrija esa ruta, el Mac **no** está vigilado por este fichero. |
| `plan-response.json`, `plan-all-excluded-response.json`, `plan-blocked-response.json` | Android: `RelaunchPlanContractTest`. |
| `plan-window-request.json` | Android: `AgentCatalogCodecTest`. |
| `apply-response.json`, `apply-recovered-response.json`, `apply-in-progress-response.json` | Android: `RelaunchOperationContractTest` (si terminó lo dice `operation_state`, no `recovered`). |
| `plan-request.json`, `apply-request.json`, `status-request.json`, `errors.json` | Nadie todavía. |

Linux no lee ninguno: el motor de relanzado de la rama `desarrollo/relaunch-linux-20260914` todavía
no está portado a esta. Las pruebas de Android se han escrito o cambiado el 24-09-2026 sin
ejecutarlas: Gradle está prohibido hasta nuevo aviso.

Causas añadidas: `sin_ia` (24-09-2026), para una ventana sin ninguna IA en marcha. Ya llegaba en
`plan-all-excluded-response.json` y Android la conservaba como identificador sin traducir; ahora la
conoce (`RelaunchCause.NO_AGENT`). El Mac (`RelaunchCause` en `Packages/CMUXAgentLaunch`) todavía no.

Dos campos que se confunden y no son lo mismo: **`recovered`** dice que la operación **ya existía**,
y **`operation_state`** dice si **terminó**. Una operación recuperada puede seguir en curso.

Regla que se comprueba con `apply-recovered-response.json`: **recuperar el resultado de algo que ya
se hizo no puede exigir un plan nuevo.** Si lo exigiera, un corte de red entre el cierre y la
respuesta se convertiría en trabajo perdido, que es justo lo que este contrato existe para evitar.

Y una que se comprueba mirando quién pide: la excepción de caducidad al recuperar es **solo a la
caducidad**. Sigue haciendo falta un dispositivo autorizado ahora y que sea el dueño de esa
operación. Un token caducado no es una llave maestra.
