# Ejemplos normativos de `window_details.v1`

Estos ficheros **son el contrato**, no una ilustración. Si un ejemplo y una implementación
discrepan, manda el ejemplo. El modelo que hay detrás está en `docs/ARBOL-IA-v1.md`.

| Archivo | Qué fija |
|---|---|
| `details-request.json` | Forma de `mobile.terminal.details`. |
| `details-response-local.json` | Ventana local del Mac con Claude en marcha. |
| `details-response-ssh.json` | Ventana SSH con Claude como root: `IS_SANDBOX=1` en la orden. |
| `details-response-no-agent.json` | Ventana SSH sin IA ni guardada ni en vivo: `agent: null` y `reason: "sin_ia"`. |
| `details-response-saved-shell.json` | IA guardada (Codex) y la ventana ahora en un shell: `agent` con lo guardado, `state: "guardado"`, y `reason: "sin_ia"`. |
| `details-response-sin-id.json` | IA en marcha sin identificador (`claude login`): `session_id`, `source` y `resume` a `null`, y `reason: "sin_id"`. |
| `details-response-interrupted.json` | Ventana local cuya IA quedó interrumpida y cuyo tmux no está en marcha. |
| `details-response-no-tmux.json` | Ventana antigua sin tmux: `tmux: null` y `reason: "sin_tmux"`. |
| `details-response-local-unreachable.json` | Ventana local cuya comprobación en vivo falló: lo guardado y `reason: "host_inaccesible"`. |
| `details-response-vault-closed.json` | Ventana SSH con la bóveda cerrada: `host: null`, `host_label` del perfil, `as_root` sacado de la etiqueta y `reason: "host_inaccesible"`. |
| `filas.json` | El texto exacto de cada fila del modal para cada respuesta de arriba. |
| `errors.json` | Errores de la llamada, con cuándo salen y el mensaje en español. |

## Quién lee qué (a 24-09-2026)

Solo lo que existe en el repositorio. Afirmar una lectura que no ocurre es peor que no apuntarla.

| Archivo | Lo lee hoy | Tiene que leerlo |
|---|---|---|
| `details-response-local.json`, `-ssh.json`, `-no-agent.json` | Android: `WindowDetailsContractTest` los pasa por `NativeMachineClient.decodeDetails` (`android/app/build.gradle.kts` copia el directorio entero a los recursos de prueba). Mac: `cmuxTests/UniConnectWindowDetailsSnapshotTests` compara con ellos instantáneas **montadas a mano**, no la lógica de `windowDetails`, y si falta el fichero sale sin comparar (`return`). Escritos el 24-09-2026 sin ejecutarlos: no se compila hasta nuevo aviso. | Los tests de lógica del Mac (inspector local y sonda falsos, D8) y los de `linux/uniconnect/window_details.py`, con **todas** las respuestas. |
| Las otras seis respuestas y `filas.json` | Nadie todavía (nuevas el 24-09-2026). | Mac, Linux y Android: cada respuesta decodificada y pintada tiene que dar exactamente sus filas de `filas.json`. |
| `details-request.json`, `errors.json` | Nadie todavía. | Las pruebas del RPC del Mac y de `linux/uniconnect/mobile_rpc.py`. |

Un test que lee `contracts/` falla si no encuentra el fichero (`#require` en Swift, `assert` en
Python, `requireNotNull` en Kotlin). Nunca sale en verde sin haber comparado nada.

## Llamada

- Método `mobile.terminal.details`, y también `terminal.details`. El socket local de escritorio lo
  atiende igual: en el Mac, `terminal.details` en el despacho v2 del socket; en Linux, `details` en
  `control.py`. Mismo JSON en los tres sitios.
- El equipo anuncia `window_details.v1` en `capabilities` de `mobile.workspace.list` (y en
  `mobile.host.status` en Linux). Sin ella, Android no enseña la entrada «Detalles».
- Parámetros: `workspace_id` y `terminal_id`. Se acepta `surface_id` como alias de `terminal_id`; si
  vienen los dos y no coinciden, `invalid_params`.
- Es **solo lectura**: no persiste nada ni lanza nada. Tarda como mucho 10 s (la sonda, ≤ 8 s).
- Si la comprobación en vivo falla o vence, responde **con lo guardado** y `reason:
  "host_inaccesible"`. Nunca un error por la sonda.

## Respuesta

Todas las claves están siempre; las que no aplican van `null`. Las fechas, en ISO 8601 UTC (`Z`).

- `version`: 1. `checked_at`: cuándo se armó la respuesta.
- `workspace`: `{name, kind, host, host_label}`. `kind` es `local` o `ssh`.
  - Local: `host` y `host_label` son `null`.
  - SSH con la bóveda abierta: `host` es `{user, hostname, port}` del **destino efectivo resuelto**
    (el Mac, con `UniConnectSSHEffectiveTarget`; Linux, con `endpoint_key()` resolviendo con
    `ssh -G`, siempre en el hilo de trabajo y nunca en el de GTK). `host_label` es
    `"<user>@<hostname>:<port>"` de ese mismo destino.
  - SSH con la bóveda cerrada (no hay credencial con la que resolver): `host` va `null` y
    `host_label` sale de la etiqueta guardada en el perfil. Esa etiqueta se guarda ya resuelta,
    `usuario@host:puerto`, al crear, editar o conectar la caja. Una etiqueta antigua se normaliza al
    leerla: sin puerto, `:22`. Única excepción al formato: una etiqueta antigua sin usuario (un alias
    de `~/.ssh/config`) viaja como `host:puerto`.
  - IPv6 entre corchetes: `root@[2001:db8::1]:22`.
  - **Jamás** viajan la orden de conexión, contraseñas ni `credentialId`.
- `window`: `{name}`.
- `tmux`: `{socket, session, session_id, pane_id, live}`. `default` es el servidor por defecto.
  `live` es `true` solo si la comprobación de ahora vio la sesión; entonces `session_id` y `pane_id`
  (el panel que decidió) son los de tmux. Si no la vio, o no se pudo comprobar, `live: false` y los
  dos ids a `null`. Ventana antigua sin tmux: `tmux: null`.
- `agent`: `{provider, display_name, session_id, cwd, as_root, source, state, observed_at, resume}`
  o `null`. Se elige así, en este orden:
  1. **La IA en marcha**, si la comprobación de ahora vio exactamente una en la ventana (con o sin
     id): `state: "activo"`, `source` el de la sonda, `observed_at` el momento de esa lectura. Sin
     id: `session_id`, `source` y `resume` van `null`.
  2. Si no, **la última IA guardada de la ventana**: la conversación activa guardada o, si no hay,
     la más reciente de su historial, **aunque la ventana esté ahora en un shell**.
     `state: "interrumpido"` si está marcada como interrumpida y `"guardado"` si no;
     `source: "registro"`; `observed_at`, la última vez que se vio viva (o `null` si no consta).
  3. Si no hay ninguna de las dos: `null`.
  - `provider`: `claude`, `codex`, `agy`, `grok` u otro id de `agent-resume-v1.json` (el Mac
    traduce `antigravity` a `agy`).
  - `display_name`: el `displayName` de ese proveedor en `agent-resume-v1.json` (`Claude Code`,
    `Codex`, `Antigravity`, `Grok`). Un proveedor sin `displayName` usa su id tal cual. Ninguna
    plataforma lleva su propia tabla de nombres.
  - `as_root`: el de la sonda si la IA está en marcha; si no, el guardado; si tampoco consta, el
    usuario del destino es `root` (el de `host`, o si `host` es `null`, la parte de `host_label`
    antes de `@`). En local, `false` si no consta.
  - `resume`: `{argv, environment, command, no_prompt_verified}`, o `null` sin `session_id`. Se
    deriva, nunca se persiste, y sale igual que en `contracts/agent-tree-v1/reanudar-comandos.json`,
    en su forma canónica (sin opciones de ventana).
- `reason`, con esta precedencia:
  1. `sin_tmux` si `tmux` es `null` (no se comprueba nada en vivo).
  2. `host_inaccesible` si la comprobación en vivo falló o venció, en local o en SSH, haya o no algo
     guardado. La bóveda cerrada cuenta como comprobación fallida.
  3. Si la comprobación vio la sesión: lo que dijo la sonda de ella, `null`, `sin_id`, `sin_ia` o
     `identidad_ambigua`. `panel_muerto` se enseña como `sin_ia` (solo aquí, al enseñarlo: nunca
     convierte lo guardado en shell).
  4. Si la comprobación fue bien y la sesión no está en marcha: `null`.
  - `sin_id` sale **solo** de una IA en marcha sin id. Una IA guardada sin id no cambia `reason`.

## Textos del modal «Detalles» (Mac, Linux y Android, literales)

`filas.json` trae, para cada respuesta de este directorio, las filas exactas que salen. Las reglas:

**Marco**

| Qué | Texto |
|---|---|
| Entrada del menú | Mac y Linux: «Detalles…». Android: «Detalles». |
| Título | «Detalles de la ventana» |
| Mientras llega la comprobación (escritorio; Android, mientras espera la respuesta) | «Comprobando…» |
| Aviso encima de las filas si `reason` es `host_inaccesible`, en SSH | «No se pudo comprobar el servidor; se muestra lo guardado» |
| El mismo aviso en local | «No se pudo comprobar tmux en este equipo; se muestra lo guardado» |
| Android, si la llamada misma falla | «No se han podido pedir los detalles de esta ventana.» |
| Botones | «Copiar orden» (solo si hay `resume`) y «Cerrar». Tras copiar: «Orden copiada». |

**Filas, en este orden.** Las de la IA (8 a 13) solo salen si `agent` no es `null`. Un valor vacío
o `null` se enseña como «—». Un `state` o un `source` que el cliente no conoce se enseña tal cual.

| # | Etiqueta | Valor |
|---|---|---|
| 1 | Espacio de trabajo | `workspace.name` |
| 2 | Tipo | Local: «Local». SSH: «VPS (`host_label`)»; sin `host_label`, «VPS». |
| 3 | Ventana | `window.name` |
| 4 | Socket tmux | «Servidor tmux por defecto» si `socket` es `default`; si no, el nombre del socket. |
| 5 | Sesión tmux | `tmux.session` |
| 6 | ID tmux | Con `live`: «`session_id` · `pane_id`» (sin `pane_id`, solo `session_id`). Sin `live` y `reason` `host_inaccesible`: «Sin comprobar». Si no: «No está en marcha ahora». |
| 4–6 | (sin tmux) | Las tres se sustituyen por una sola: «Sesión tmux» → «Sin tmux: terminal directa sin sesión recuperable». |
| 7 | IA | Ver la tabla siguiente. |
| 8 | Estado | Ver la tabla siguiente. |
| 9 | ID de conversación | `agent.session_id`, o «—». |
| 10 | Carpeta | `agent.cwd`, o «—». |
| 11 | Como root | «Sí» o «No». **Solo en SSH.** |
| 12 | Origen del dato | `ficha` «Ficha de sesión de Claude» · `rollout` «Registro abierto de Codex» · `argv` «Línea de órdenes del proceso (puede estar desfasada)» · `hook` «Aviso del propio agente» · `manifiesto` «Supervisor del servidor» · `registro` «Guardado en UniConnect» · `null` «—». |
| 13 | Orden para reanudarla | `resume.command`, monoespaciada y seleccionable. Solo si hay `resume`. Si `no_prompt_verified` es `false`, debajo: «Sin modo sin preguntas verificado para esta IA». |

**Fila 7, «IA»** (gana la primera que encaja):

| Caso | Texto |
|---|---|
| `reason` es `identidad_ambigua` | «Hay más de una IA en esta ventana» |
| Sin `agent` y `reason` `host_inaccesible` | «Sin IA guardada» |
| Sin `agent` (sin IA, sin tmux, sesión parada) | «Sin IA detectada» |
| `agent` en marcha sin id (`sin_id`) | «`display_name`: IA detectada, sin identificador todavía» |
| `agent` guardado sin id | «`display_name`: sin identificador guardado» |
| Cualquier otro `agent` | «`display_name`» |

**Fila 8, «Estado»**:

| `agent.state` | Texto |
|---|---|
| `activo` | «En marcha» |
| `interrumpido` | «Interrumpida: se reanudará al abrir» |
| `guardado` con `reason` `sin_ia` (guardada y ahora en un shell) | «Guardada; ahora no hay ninguna IA en marcha» |
| `guardado` en cualquier otro caso | «Guardada (no comprobada ahora)» |

**Casos por los que se pregunta, y dónde se ven:**

| Caso | Respuesta de ejemplo | Lo que cambia en las filas |
|---|---|---|
| Sin tmux | `details-response-no-tmux.json` | «Sesión tmux: Sin tmux: terminal directa sin sesión recuperable»; «IA: Sin IA detectada». |
| Sin IA | `details-response-no-agent.json` | «IA: Sin IA detectada» y ninguna fila más de IA. |
| `sin_id` | `details-response-sin-id.json` | «IA: Claude Code: IA detectada, sin identificador todavía»; «ID de conversación: —»; «Origen del dato: —»; sin orden. |
| Guardada y ahora en shell | `details-response-saved-shell.json` | «IA: Codex»; «Estado: Guardada; ahora no hay ninguna IA en marcha»; la orden, igual. |
| Interrumpida | `details-response-interrupted.json` | «Estado: Interrumpida: se reanudará al abrir»; «ID tmux: No está en marcha ahora». |
| Comprobación fallida en local | `details-response-local-unreachable.json` | Aviso «No se pudo comprobar tmux en este equipo; se muestra lo guardado»; «ID tmux: Sin comprobar». |
| Servidor inaccesible (SSH, aquí con la bóveda cerrada) | `details-response-vault-closed.json` | Aviso «No se pudo comprobar el servidor; se muestra lo guardado»; «Tipo: VPS (root@167.233.192.135:22)» aunque `host` sea `null`; «Como root: Sí» por la etiqueta. |

En el Mac, cada texto tiene su clave en `Resources/Localizable.xcstrings` (solo `es`); en Linux va
directo en español; en Android, en `res/values/strings.xml`. El texto que se ve es el de estas
tablas, letra por letra.

## Errores

En el RPC viajan como siempre, `{code, message}`. `errors.json` da, por cada `code`, cuándo sale
(`cuando`) y el `mensaje` en español que pone el equipo en `message`.
