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
| `proveedores.json` | Qué IA sabe relanzar cada equipo por tipo de ventana (tras D7), y los tokens con los que lo anuncia. |

## Quién lee qué (a 24-09-2026)

Solo lo que existe en el repositorio. Afirmar una lectura que no ocurre es peor que no apuntarla:
da por vigilado un fichero que nadie mira.

| Archivo | Lo lee hoy |
|---|---|
| `causes.json` | Android: `RelaunchTest` exige que `RelaunchCause` sea exactamente este conjunto. Mac: `RelaunchCauseCatalogueTests` lo pretende, pero sube cuatro carpetas desde su fichero y lo busca en `Packages/contracts/…`, que no existe; al no encontrarlo sale sin comparar nada. Hasta que se corrija esa ruta (D8: subir hasta encontrar `contracts/` y `#require`), el Mac **no** está vigilado por este fichero. |
| `plan-response.json`, `plan-all-excluded-response.json`, `plan-blocked-response.json` | Android: `RelaunchPlanContractTest`. |
| `plan-window-request.json` | Android: `AgentCatalogCodecTest`. Linux: `linux/tests/test_relaunch.py`. |
| `apply-response.json`, `apply-recovered-response.json`, `apply-in-progress-response.json` | Android: `RelaunchOperationContractTest` (si terminó lo dice `operation_state`, no `recovered`). Linux: `test_relaunch.py` compara las claves de su `apply` con las de `apply-in-progress-response.json`. |
| `plan-request.json` | Linux: `test_relaunch.py` resuelve su alcance. |
| `proveedores.json` | Nadie (nuevo el 24-09-2026). Lo tienen que leer los tests de capacidades del Mac y de Linux (lo que anuncia cada equipo es exactamente su fila de `capacidades`) y Android (cuándo ofrece «Relanzar IA de esta ventana»). |
| `apply-request.json`, `status-request.json`, `errors.json` | Nadie todavía. |

Las pruebas de Android se han escrito o cambiado el 24-09-2026 sin ejecutarlas: no se compila
hasta nuevo aviso.

Causas añadidas: `sin_ia` (24-09-2026), para una ventana sin ninguna IA en marcha. Ya llegaba en
`plan-all-excluded-response.json` y Android la conoce (`RelaunchCause.NO_AGENT`). El Mac
(`RelaunchCause` en `Packages/CMUXAgentLaunch`) todavía no.

Dos campos que se confunden y no son lo mismo: **`recovered`** dice que la operación **ya existía**,
y **`operation_state`** dice si **terminó**. Una operación recuperada puede seguir en curso.

Regla que se comprueba con `apply-recovered-response.json`: **recuperar el resultado de algo que ya
se hizo no puede exigir un plan nuevo.** Si lo exigiera, un corte de red entre el cierre y la
respuesta se convertiría en trabajo perdido, que es justo lo que este contrato existe para evitar.

Y una que se comprueba mirando quién pide: la excepción de caducidad al recuperar es **solo a la
caducidad**. Sigue haciendo falta un dispositivo autorizado ahora y que sea el dueño de esa
operación. Un token caducado no es una llave maestra.

## Qué relanza cada equipo (D7, 24-09-2026)

Antes de D7 el Mac solo sabía cerrar Claude y Linux solo Codex, y los dos anunciaban `relaunch.v1`
igual. D7 porta el dialecto que falta a cada lado. La matriz resultante, que fija
`proveedores.json`:

| Proveedor | Mac, ventana local | Mac, ventana SSH | Linux, ventana local | Linux, caja SSH |
|---|---|---|---|---|
| Claude | sí | `no_soportado` | escrito, **pendiente de prueba en vivo** | escrito, **pendiente de prueba en vivo** |
| Codex | escrito, **pendiente de prueba en vivo** | `no_soportado` | sí | sí |

«Pendiente de prueba en vivo» (decisión del 24-09-2026): el dialecto está escrito y probado con
dobles, pero relanzar **cierra la IA** y nunca se ha ejecutado contra una real. Hasta esa prueba no
se anuncia y el plan lo excluye con `no_soportado` (`pendiente_prueba_en_vivo` en
`proveedores.json`). Se activa añadiéndolo a `RelaunchDialects.known` (Mac) o a `RELAUNCHABLE`
(Linux) en el mismo commit que la prueba.
| agy, grok y el resto del catálogo | `no_soportado` | `no_soportado` | `no_soportado` | `no_soportado` |

- **Mac SSH** sigue en `no_soportado`: la `ClosurePolicy` rechaza `.ssh`. Una ventana SSH pedida por
  id desde el móvil devuelve esa exclusión, no `alcance_no_valido`.
- **Linux SSH** usa el mismo trabajador que en local, ejecutado en el destino por el canal de la
  caja. Necesita un destino Linux (`/proc` y `pidfd_open`); si no los hay, `no_soportado`.

### Lo que exige cada dialecto (igual en las dos plataformas)

- **Claude** (el Mac ya lo tiene en `ClaudeRelaunchDialect`; Linux lo calca):
  - Identidad probada antes de cerrar. El Mac usa `RelaunchIdentityEvidence` (un único candidato
    entre cerrojos, rollouts y un hook que coincide en proceso y panel) y el id que Claude imprime al
    salir («Resume this session with»). Linux (D7) solo lo intenta con la ficha
    `~/.claude/sessions/<pid>.json` de la raíz en `status: "idle"`. Sin identidad probada:
    `identidad_ambigua`.
  - Solo con el compositor vacío. Linux, si la ficha no está en `idle` o el compositor no está vacío,
    excluye sin tocar nada con `dialogo_desconocido`, la misma causa que ya usa su trabajador de
    Codex. Un diálogo de confianza de carpeta es `confianza_carpeta`; uno de permisos, `permisos`.
    Nunca se contesta por nadie. La pregunta de trabajo en segundo plano se resuelve eligiendo la
    opción por su texto, nunca por su posición (`RelaunchScreenReading`).
  - Cierra escribiendo `/exit` (nunca Ctrl+C) y comprobando la línea antes de Intro.
  - Reabre con `[IS_SANDBOX=1 ]claude --resume <id> <opciones vivas saneadas>
    --dangerously-skip-permissions`, con la política `noPrompt` del catálogo. `IS_SANDBOX=1` solo si
    la raíz es de root (en el Mac local, nunca).
  - `verificado` exige un proceso nuevo con la **misma** conversación.
- **Codex** (Linux ya lo tiene en `TargetWorker.exit_codex`; el Mac lo calca):
  - Identidad: el rollout que tiene abierto (regla de `contracts/agent-tree-v1`).
  - Compositor vacío: `›` solo, o el marcador atenuado «› Ask Codex to do anything» con el cursor en
    la columna 2. Si en pantalla hay una pregunta de permisos o de confianza, `permisos`.
  - Cierra escribiendo `/exit` literal, espera a ver «› /exit» en la línea del cursor, y solo
    entonces Intro. Espera a que el proceso muera (≤ 75 s) sin matarlo; si no muere,
    `dialogo_desconocido`.
  - Reabre con `codex --yolo resume <id> <opciones conservadas>`, con `supersedes` aplicado (quita
    `-a`, `--ask-for-approval`, `-s`, `--sandbox`, `--full-auto`).
  - `verificado` exige la misma conversación viva otra vez.
- El Mac guarda el id verificado con el **proveedor del objetivo** (`recordRelaunchedConversations`),
  nunca con `claude` fijo.

### Cómo lo anuncia el equipo

En `capabilities` (de `mobile.workspace.list`, de `mobile.host.status` en Linux y del `status` del
socket de control de Linux), además de `relaunch.v1`, un token por celda soportada:
`relaunch.v1.<proveedor>.<tipo>`, con `<tipo>` `local` o `ssh`. La lista exacta de cada equipo es
su fila de `capacidades` en `proveedores.json`.

- Un equipo solo anuncia una celda cuando su dialecto está hecho y probado. El token es una pista
  para la interfaz, no una autorización: el plan sigue excluyendo con causa lo que no puede hacer.
- Android, con `relaunch.v1` y **algún** token `relaunch.v1.*.*`: ofrece «Relanzar IA de esta
  ventana» solo si está anunciado el par (proveedor, tipo) de la ventana; si no sabe el proveedor de
  la ventana, lo ofrece cuando hay algún token de su tipo. Con `relaunch.v1` y **ningún** token
  (equipo anterior a D7), lo ofrece como hasta ahora y deja que el plan excluya.
- Los alcances `workspace` y `machine` se ofrecen con `relaunch.v1` a secas: el plan enseña lo que
  entra y lo que no, con su causa.
