# Ejemplos normativos de `agent-tree.v1`

Estos ficheros **son el contrato**, no una ilustración. Si un ejemplo y una implementación
discrepan, manda el ejemplo. El documento que los explica es `docs/ARBOL-IA-v1.md`.

| Archivo | Qué fija |
|---|---|
| `deteccion-casos.json` | El criterio común de detección (qué IA hay en un panel y con qué conversación) y la guarda de conversación abierta. |
| `reanudar-comandos.json` | La orden exacta con la que se reanuda cada IA, siempre sin preguntas, con y sin opciones conservadas, y el nombre que se enseña de cada proveedor. |
| `sonda-salida.json` | La salida v1 de `linux/uniconnect/agent_probe.py`, tal cual la emite (generada con `probe()` y un lector falso). La comparten Linux, el Mac en SSH y el supervisor VPS. |
| `sonda-lectura.json` | Qué hace quien lee la sonda con cada sesión de `sonda-salida.json`, y las salidas de error y de límite con lo que se puede deducir de cada una. |
| `arbol-ejemplo.json` | El árbol de un equipo en el cable: un espacio local y uno SSH. |

## Quién lee qué (a 24-09-2026)

Solo se apunta lo que existe en el repositorio. Lo que falta va en su propia columna.

| Archivo | Lo lee hoy | Tiene que leerlo |
|---|---|---|
| `deteccion-casos.json` | `linux/tests/test_recovery_v2.py`, contra `detect_agent` y `guard` de `linux/scripts/recovery.py`. `linux/tests/test_agent_probe.py` lo abre, pero su arnés exige `esperado`/`expected` y `reason` (el fichero trae `espera` y `cause`) y busca `cwd_procesos` y `primeras_lineas` en vez de `cwds` y `rollouts`: falla en cada caso sin llegar a comparar. `AgentProcessDiscoveryTests` (Mac) sube cuatro carpetas y lo busca en `Packages/contracts/…`: sale sin comparar. | Los tres, con las claves de este fichero (`espera`, `cause`, `cwds`, `rollouts`, `enlaces`), y también `agent_guard.py`. Los siete casos añadidos el 24-09 fallan hoy en al menos una implementación: ver «Decisiones del 24-09». |
| `reanudar-comandos.json` | `test_recovery_v2.py` (`canonical_resume`, `command_for`) y `test_resume_catalog.py` (`no_prompt_resume`), las dos **sin** pasar `arguments`. `AgentNoPromptPolicyTests` (Mac) sí pasa `arguments`, pero tiene el mismo fallo de ruta. | Todas pasando `arguments` (lista vacía si el caso no la trae) y comparando `display_name` con el `displayName` del catálogo. |
| `sonda-salida.json` | `AgentProbeReportTests` (Mac), con el fallo de ruta y esperando la forma antigua (`panes` arriba). Ningún test de Linux compara `probe()` con él. | `test_agent_probe.py`: `probe()` con el lector falso de este ejemplo tiene que dar este JSON. `AgentProbeReport` (Mac) y `AgentTree` (Linux) lo decodifican. |
| `sonda-lectura.json` | Nadie (nuevo el 24-09-2026). | Los lectores de la sonda: `AgentProbeReport` + `UniConnectRemoteAgentMonitor` (Mac) y `AgentTree` (Linux). |
| `arbol-ejemplo.json` | Nadie. | Referencia de forma; ninguna llamada lo devuelve entero hoy. |

**Cómo encuentra un test este directorio (D8).** Sube carpeta a carpeta desde su propio fichero
(`#filePath` en Swift, `__file__` en Python) hasta la primera que contiene `contracts/`. Si no la
encuentra, **falla** (`try #require` / `assert`): nunca `return` en silencio ni `skip`. Un test que
sale en verde sin haber comparado nada es peor que no tenerlo.

## `deteccion-casos.json`

```
{ "version": 1,
  "casos":  [ { nombre, descripcion?, pane_pid, home, procesos, fichas, abiertos, rollouts,
                cwds?, enlaces?, pane_current_path?, espera } ],
  "guarda": [ { nombre, descripcion?, proveedor, id, home, fichas_vivas, procesos, abiertos,
                cerrojos, proc_legible?, espera } ] }
```

### Un caso de detección

- `pane_pid`: el `#{pane_pid}` de tmux, que es el **shell** del panel, no la IA.
- `home`: el HOME de quien sondea.
- `procesos`: la tabla entera de `ps -eo pid=,ppid=,uid=,args=` (o de /proc), con `{pid, ppid, uid, argv}`.
  Puede traer procesos de fuera del subárbol del panel, y `entorno` en alguno de ellos. El criterio
  **nunca** mira el entorno.
- `fichas`: el contenido de `~/.claude/sessions/<pid>.json`, indexado por el pid del nombre del
  fichero. El arnés la sirve donde la buscaría la implementación: en `/root/.claude/sessions/<pid>.json`
  si el proceso es de uid 0, y en `<home>/.claude/sessions/<pid>.json` en los demás casos. La ficha
  real trae su propio `pid` dentro; algunos casos lo incluyen.
- `abiertos`: los ficheros que tiene abiertos cada pid (`readlink /proc/<pid>/fd/*` en Linux;
  `lsof -n -P -p <pid> -Fn` en macOS).
- `rollouts`: la **primera línea** de cada rollout de Codex, tal cual, como texto JSON.
- `cwds`: el cwd de cada proceso (`/proc/<pid>/cwd`, o `lsof -a -p <pid> -d cwd -Fn`). Opcional.
- `enlaces`: rutas que son enlaces simbólicos y su destino real, por coincidencia exacta. Opcional.
- `pane_current_path`: el último recurso para el cwd. Opcional.

`espera` tiene tres formas:

- IA identificada: `{provider, session_id, cwd, as_root, source}`.
- IA detectada sin id: lo mismo con `session_id: null`, `source: null` y `cause: "sin_id"`.
- Sin IA o ambigua: `{cause: "sin_ia"}` o `{cause: "identidad_ambigua"}`.

**Se comparan solo las claves que trae `espera`.** Una implementación puede devolver más (el pid de
la raíz, `status`, `version`), pero no puede contradecir ninguna de las que están.

### El criterio (normativo)

1. **Subárbol**: los descendientes de `pane_pid`, en anchura sobre la tabla de procesos
   (profundidad ≤ 8, ≤ 256 nodos). Nunca con `pgrep -P`, que en macOS excluye a los ancestros del
   propio pgrep. Si `pane_pid` no está en la tabla, el panel está muerto (`panel_muerto`).
2. **Es de un proveedor** (la ficha **nunca** clasifica a un proceso: solo da identidad a uno que ya
   es Claude). Llamamos node a un basename de argv0 que cumple `^(node|nodejs|bun)(\d+(\.\d+)*)?$`.
   - **claude**: basename(argv0) es `claude`; o argv0 contiene `/claude/versions/`; o node con un
     argumento que contiene `@anthropic-ai/claude-code` **o cuyo basename es exactamente `claude`**
     (Claude de npm lanzado por su shebang).
   - **codex**: basename(argv0) empieza por `codex` (incluye `codex-x86_64-unknown-linux-musl`); o
     node con un argumento que contiene `@openai/codex` o cuyo basename es `codex` o `codex.js`.
   - **agy**: basename `agy` o `antigravity`. **grok**: basename `grok` o que empieza por `grok-`.
   - sudo, doas, env, los shells, login, tmux, python y un node sin marca no son IA. Sus
     descendientes ya están en el subárbol.
3. **Raíz** = proceso de proveedor sin antepasado de proveedor **dentro del subárbol**. 0 raíces:
   `sin_ia`. 2 o más: `identidad_ambigua`. Exactamente 1: esa IA.
4. **Valor de una opción en argv** (lo usan Claude, agy y grok):
   - Solo cuenta lo que va antes del primer `--`. Lo de detrás es texto para la IA.
   - `<opción> <valor>`: el valor es el token siguiente, **salvo que empiece por `-`**: entonces esa
     aparición no trae valor.
   - `<opción>=<valor>`: solo en opciones largas (`--resume=…`). `-r=…` no es una forma válida.
   - Se recogen **todos** los valores de las opciones del proveedor. Si alguno no es válido (en
     Claude, un UUID; en agy y grok, `[A-Za-z0-9_-]{1,160}`) o hay más de un valor distinto (los
     UUID se comparan en minúsculas), la línea de órdenes no da id. Si hay exactamente uno, ese.
5. **Identidad**, gana la primera fuente disponible:
   - **Claude**: la ficha de la raíz (`ficha`), si su `sessionId` es válido y su `pid` interior es el
     de la raíz o no está (fichas antiguas) → `--resume`, `-r` o `--session-id` (`argv`) → `sin_id`.
   - **Codex**: se reúnen los UUID de los `rollout-*-<uuid>.jsonl` bajo `/.codex/sessions/` que tienen
     abiertos la raíz y los procesos codex que descienden de ella (vale el **último** UUID del
     nombre). El `resume <uuid>` de argv es el token que sigue al primer `resume` antes de `--`, si es
     un UUID, buscado en la raíz y luego en su rama, en orden de anchura.
     - Un solo UUID abierto → ese (`rollout`).
     - Más de uno → solo vale el que coincide con el `resume <uuid>` de argv (`rollout`). Si ninguno
       coincide, `sin_id`. Nunca «el más reciente» ni el de argv a solas.
     - Ninguno → el `resume <uuid>` de argv (`argv`) → `sin_id`.
     - Con `rollout`, el cwd sale de `payload.cwd` de la primera línea de **ese** rollout.
   - **agy**: `--conversation <id>` (`argv`). **grok**: `-r` o `--resume <id>` (`argv`).
   - **cwd**: el de la ficha o el rollout; si no hay, el del proceso raíz; si tampoco,
     `pane_current_path`. Siempre resuelto (`enlaces`).
   - **as_root**: uid de la raíz == 0.

### Decisiones del 24-09 (divergencias de la revisión)

Las cuatro divergencias entre Swift (`AgentProcessDiscovery`) y Python (`agent_probe.py`,
`recovery.py`) se resuelven hacia el lado conservador: **ante la duda, no se da id**. Un `sin_id`
deja lo guardado como estaba; un id equivocado reanuda otra conversación, y eso no tiene arreglo.

| Caso | Decisión | Por qué | Hoy falla en |
|---|---|---|---|
| `claude_tras_doble_guion_no_hay_opciones_da_sin_id` | Tras `--` no hay opciones. | Es la convención POSIX y la del propio Claude: lo de detrás es el primer mensaje. | `agent_probe.py`, `recovery.py` |
| `claude_resume_y_session_id_distintos_da_sin_id` | Dos ids distintos en argv → `sin_id`. | Con `--fork-session` la conversación viva es la de `--session-id`; sin él, la de `--resume`. Elegir «el primero» es adivinar. Si hay ficha, manda la ficha y no hay duda. | `agent_probe.py`, `recovery.py` |
| `codex_dos_rollouts_vale_el_que_coincide_con_su_resume` y `codex_dos_rollouts_sin_resume_que_coincida_da_sin_id` | Con varios rollouts abiertos, solo el que coincide con `resume <uuid>`; si ninguno, `sin_id`. | Un `codex exec` lanzado por la propia sesión (y los hilos secundarios) abre su propio rollout, más reciente que el de la ventana. El argv a solas puede estar desfasado tras `/new`: si se usara, pisaría el id bueno que se guardó cuando solo había un rollout. | Swift (da `argv`), `agent_probe.py` y `recovery.py` (dan el más reciente) |
| `ficha_de_otro_pid_no_vale_y_manda_argv` | Una ficha cuyo `pid` interior no es el de su nombre no vale; sin `pid` interior, sí. | Claude escribe su propio pid dentro. Si no coincide, el fichero es de otro proceso (copiado o restaurado) y su conversación sería la de otro. | Swift (`AgentClaudeSessionFile` no lee `pid`), `recovery.py` |

Y dos casos que cierran el criterio «es Claude» (regla 2), porque la regla anterior («tiene ficha y
algún argumento contiene `claude`») la aplicaban Swift y `recovery.py` pero no `agent_probe.py`:

| Caso | Decisión | Hoy falla en |
|---|---|---|
| `claude_md_en_un_argumento_no_hace_claude_a_un_proceso` | `vim ~/.claude/CLAUDE.md` con la ficha de un pid reciclado es `sin_ia`. | Swift, `recovery.py` |
| `claude_de_npm_lanzado_por_shebang_da_claude` | `node /opt/homebrew/bin/claude` es Claude por el basename de su argumento. | `agent_probe.py` |

Una implementación de referencia de estas reglas pasa los 22 casos y la guarda de Claude
(comprobado el 24-09-2026 con un script fuera del repositorio; no forma parte de él).

### Un caso de guarda

La guarda decide si una conversación se puede reanudar automáticamente. Devuelve **0** si está libre,
**1** si está abierta en otra parte y **2** si no se puede comprobar. Solo el 0 permite reanudar.

- `fichas_vivas`: las fichas que hay en disco, por el pid de su nombre. Que ese pid siga vivo lo dice
  `procesos`.
- `procesos`: los procesos vivos, con `{pid, argv}`.
- `abiertos`: ficheros abiertos por pid. `cerrojos`: rutas sobre las que alguien tiene el cerrojo
  del kernel (`/proc/locks` o `flock`).
- `proc_legible: false` simula que no se pueden leer los ficheros abiertos de los procesos.

Reglas:

- id que no cumple `[A-Za-z0-9_-]{1,160}` o proveedor desconocido: 2.
- claude: 1 si hay una ficha con ese `sessionId` cuyo pid (el del nombre del fichero) está vivo y
  **es Claude por la regla 2 de detección**, la estricta: un argumento que contiene `claude` no
  basta (caso `claude_pid_reciclado_que_edita_claude_md_no_bloquea`). El `pid` interior de la ficha
  no se mira aquí: ante la duda, la guarda bloquea. La línea de órdenes no cuenta: tras `/clear`
  miente (caso `claude_argv_viejo_no_bloquea`). Este criterio es el de `agent_guard.py` y el que
  tiene que usar la guarda local del Mac (`UniConnectClaudeOpenConversationGuard.isLiveClaude`).
- codex: 1 si algún proceso tiene abierto su `rollout-*-<id>.jsonl` o alguien tiene el cerrojo de
  `~/.codex/thread-writer-locks/<id>.lock`. 2 si no se pueden leer los abiertos.
- agy: 1 si alguien tiene el cerrojo de `~/.gemini/antigravity-cli/presence/<id>.lock` o un agy vivo
  lleva ese id en su línea de órdenes.
- grok: 1 si un grok vivo lleva ese id en su línea de órdenes. No hay otra fuente.

## `reanudar-comandos.json`

`{version: 1, casos: [{nombre, descripcion?, provider, display_name, session_id, cwd, as_root,
arguments?, argv, environment, command, no_prompt_verified}]}`

- `arguments` (opcional; `[]` si falta): las opciones conservadas que van en `{arguments}` de la
  plantilla `resume` del catálogo. Quien lee el caso **tiene que pasarlas** a su función de reanudar
  (`AgentNoPromptPolicy.resume(…, arguments:)`, `AgentResumeCatalog.no_prompt_resume(…, arguments)`,
  `recovery.canonical_resume(…, arguments)`).
- `argv` es el resultado: plantilla + política `noPrompt`.
- `environment` solo lleva `IS_SANDBOX=1`, y solo en Claude como root.
- `command` es la orden de shell: `cd -- '<cwd>' && [K=V ]<argv>`. El cwd va siempre entre comillas
  simples POSIX (`'` → `'\''`). Un token de argv solo lleva comillas si tiene algo fuera de
  `[A-Za-z0-9@%_+=:,./-]`.
- `no_prompt_verified` es `true` cuando el proveedor tiene `noPrompt` en el catálogo. Grok no la
  tiene: se reanuda con su sintaxis y `false`. La de agy se hereda de `recovery.py` y de
  `AgentResumeArgv`; no se ha comprobado contra un binario real.
- `display_name` es el `displayName` del proveedor en el catálogo.

### Lo que tiene que traer el catálogo (lo edita el Mac; aquí solo se fija)

`Packages/CMUXAgentLaunch/Sources/CMUXAgentLaunch/Resources/agent-resume-v1.json`:

```json
"claude": {"displayName": "Claude Code", "noPrompt": {"suffix": ["--dangerously-skip-permissions"], "rootEnvironment": {"IS_SANDBOX": "1"}}, …},
"codex": {"displayName": "Codex",
          "noPrompt": {"prefix": ["--yolo"], "legacy": ["--dangerously-bypass-approvals-and-sandbox"],
                       "supersedes": [{"flag": "-a", "takesValue": true}, {"flag": "--ask-for-approval", "takesValue": true},
                                      {"flag": "-s", "takesValue": true}, {"flag": "--sandbox", "takesValue": true},
                                      {"flag": "--full-auto", "takesValue": false}]}, …},
"antigravity": {"displayName": "Antigravity", "aliases": ["agy"], …},
"grok": {"displayName": "Grok", …}
```

- `displayName`: texto no vacío. Lo leen el Mac y Linux para `display_name` (Detalles, etiquetas de
  relanzar). Un proveedor sin `displayName` se enseña con su id.
- `supersedes`: banderas que el modo sin preguntas **sustituye** y que la CLI rechaza junto a él.
  `flag` cumple `^--?[A-Za-z0-9][A-Za-z0-9-]*$`, `takesValue` es booleano, sin repetidas y sin
  coincidir con `prefix`, `suffix` o `legacy`. Los validadores de catálogo de Swift y de Linux
  (`AgentResumeCatalog`) tienen que aceptar las dos claves nuevas: hoy Linux rechaza cualquier clave
  que no conoce y el catálogo entero dejaría de cargar.

### La regla de aplicación (una sola, en las cuatro implementaciones)

1. `argv` = plantilla `resume` con `{executable}`, `{sessionId}` y `{arguments}`.
2. Se recorre `argv[1:]` de izquierda a derecha:
   - un token de `prefix`, `suffix` o `legacy` se quita;
   - un token igual a una bandera de `supersedes` se quita, y si `takesValue`, también el siguiente;
   - un token `<bandera>=<valor>` de una bandera de `supersedes` con `takesValue` se quita (vale
     también para las cortas: `-s=…`);
   - lo demás se queda, en su orden.
3. Resultado: `[argv[0]] + prefix + lo que quedó + suffix`. `environment` = `rootEnvironment` si
   `as_root`.
4. Aplicarla dos veces da lo mismo que una. La forma corta pegada (`-anever`) no se reconoce: el
   catálogo nunca la produce.

La aplican igual `AgentNoPromptPolicy.applying` (Mac), `AgentResumeCatalog.apply_no_prompt` (Linux),
`TargetWorker.no_prompt` del trabajador de relanzado de Linux (que lee `supersedes` del catálogo que
recibe en la petición, sin lista propia) y `recovery.canonical_argv` (VPS, con su copia en
`NO_PROMPT`, que su test compara con el catálogo). Los lanzamientos nuevos del Mac (ventana local
nueva con Claude o Codex) también salen de `AgentNoPromptPolicy`, nunca con las banderas escritas a
mano.

## `sonda-salida.json`

Es la salida de `agent_probe.py`: una sola línea JSON, compacta, de como mucho 262 144 bytes, más
un `\n` final. Quien la lee acepta hasta 262 145 bytes o quita el salto final antes de medir.
CLI: `[--socket NOMBRE|default] [--session NOMBRE]...` (`default` no pasa `-L`). Sale siempre con 0;
el mal uso sale con 2 y sin JSON.

```
{version, checked_at, socket, host, server, error, truncated, sessions: [
  {name, session_id, pane_id, pane_pid, live, reason, agent, panes: [
    {pane_id, window_index, pane_pid, dead, current_path, current_command}]}]}
```

- `host`: `{hostname, uid, platform}` de quien sondeó (`uid` 0 = root). `null` si la sonda falló.
- `server`: `true` si el servidor tmux de ese socket respondió con paneles. `false` con `error: null`
  = no hay servidor en ese socket (o no tiene sesiones): **todas** sus sesiones faltan.
- `error`: `null`, `tmux_no_disponible` (no hay tmux o no se pudo ejecutar), `tmux_fallo` (tmux
  contestó con un error que no es «no server running») o `sonda_fallo: <Tipo>` (excepción dentro de
  la sonda; el código es lo que va antes de `:`). Con error, `sessions` va vacío y quien lee **no
  toca nada guardado** ni da nada por desaparecido.
- `truncated`: `true` si había más procesos (> 4096) o paneles (> 2048) de los que se leen, o si la
  salida no cabía y se quitaron paneles o sesiones del final. Con `truncated`, que falte una sesión
  no dice nada.
- `sessions`: una entrada por sesión tmux (las pedidas con `--session`, o todas). La sonda ya las
  agrega con `combine`:
  - `pane_id` y `pane_pid`: los del panel que decidió (el único con IA; si no hay, el primero vivo;
    si todos están muertos, el primero).
  - `live`: la sesión existe ahora. La sonda siempre pone `true`; `false` solo lo usa quien sintetiza
    una entrada que no vio, y se lee igual que `panel_muerto`.
  - `reason`: `null` (IA con id), `sin_id` (IA sin id: `agent` con `session_id: null`), `sin_ia`,
    `identidad_ambigua` (IA en más de un panel, o dos raíces) o `panel_muerto` (todos sus paneles
    muertos, o el shell del panel ya no está en la tabla de procesos).
  - `agent`: `{provider, session_id, cwd, as_root, source, pid, status, version, proc_start}` o
    `null`. `status`, `version` y `proc_start` salen de la ficha de Claude; en los demás, `null`.
  - `panes`: todos los paneles de la sesión, muertos incluidos (`dead`).
- Límites: ≤ 10 s por llamada (quien la lanza corta a los 10 s).

## `sonda-lectura.json`

`{version, sesiones: [{sesion, efecto, provider?, session_id?, cwd?, as_root?, source?, pane_id}],
salidas: [{nombre, descripcion, argumentos, salida, espera: {error, ausente_es_desaparecida}}]}`

`efecto` es lo que hace con el registro de esa ventana quien lee la sonda (Mac:
`UniConnectRemoteAgentMonitor`; Linux: `AgentTree`):

| `reason` de la sesión | `efecto` | Qué se hace |
|---|---|---|
| `null` | `ia` | Esa IA pasa a activa (estado `agent`). Si el id cambió, la vieja va al historial. |
| `sin_id` | `sin_id` | La conversación guardada **no** se toca. |
| `sin_ia` (de un panel **vivo**) | `shell` | Estado `shell`; la última IA queda en el historial y no se reanuda sola. Es el **único** caso que lleva a shell (`observeShell` en el Mac). |
| `identidad_ambigua` | `nada` | No se toca nada. |
| `panel_muerto`, o `live: false` | `nada` | No se toca nada. **Nunca** es shell: un panel muerto con `remain-on-exit` no dice que la IA se cerrara. |

`espera.error` es el código de error (sin el `: <Tipo>`). `espera.ausente_es_desaparecida` dice si
una sesión que no está en `sessions` se puede dar por desaparecida: solo con `error: null` y
`truncated: false` (con `server: false`, faltan todas). Es la única entrada para las reglas de
interrumpida y de recuperación de abajo.

## Quién recupera cada sesión (D6)

Una sesión tmux que falta la recrea automáticamente **un solo dueño**, y solo en su socket. Los
sockets no se unifican: no se pueden mover sesiones vivas de un servidor tmux a otro.

| Socket | Dueño de la recuperación automática | Qué sesiones son suyas |
|---|---|---|
| `uniconnect-local` (o `uniconnect-local-<sha8>` con tag) en el Mac | UniConnect Mac | Las de sus ventanas locales (`record.tmuxBinding`). |
| `default` en un VPS, abierto desde el Mac | UniConnect Mac que tiene esa ventana SSH | Las que creó él para sus ventanas SSH (`uniConnectTmuxSessionsByPanelId` + registro remoto del panel). |
| `uniconnect-local` en Linux | UniConnect Linux | Las de sus ventanas (`state.json`: `record.tmux`, `record.tmuxSocket`). |
| `record.tmuxSocket` o `uniconnect` en un VPS, abierto desde Linux | UniConnect Linux que tiene esa caja | Las de sus ventanas (`state.json`). |
| `manifest.tmuxSocket` y `tmuxSockets` del VPS | Supervisor `recovery.py` | Solo las entradas de **su manifiesto**. Una sesión viva cuyo `@uniconnect_session_id` no es su `tmuxOwner` se salta y se avisa. Las adoptadas (vivas sin `@uniconnect_session_id`) nunca se reconfiguran; si caen, las recrea con `missing_is_deliberate`. |

- Si dos dueños apuntan al mismo socket y al mismo nombre (una ventana del Mac en `default` que el
  supervisor también vigila), arbitra tmux: el primero la crea y el otro se engancha (Mac,
  `new-session -A`) o la encuentra ya creada (supervisor, `new-session -d` falla y `has-session` la
  ve). La orden de reanudar solo corre en quien la crea. En sockets distintos no hay arbitraje: por
  eso cada ventana tiene un solo dueño y la guarda de conversación abierta va siempre delante.
- **Recuperación remota automática** (Mac SSH y Linux SSH; D6): solo si la última lectura en vivo
  que vio esa sesión tiene como mucho **2 ticks** (≤ 120 s: el sondeo SSH es de 60 s) y la ventana
  no tiene marca de cierre deliberado. Hay marca cuando el usuario la cerró desde UniConnect (cerrar
  la ventana, cerrar su tmux, olvidarla) y cuando una lectura del socket entero (sin `--session`,
  sin error y sin `truncated`) trae el servidor vivo con otras sesiones y falta solo esta: es la regla
  de `missing_is_deliberate` de `recovery.py`, alguien la cerró a propósito. Así no resucita una IA
  que alguien mató a mano en el VPS.
  Consecuencia aceptada: tras un reinicio largo del VPS la recrea el supervisor si está en su
  manifiesto; si no, el usuario la reabre a mano («Reabrir terminal»), que no es automática.
  Estas condiciones deciden si se **reanuda la IA**; sin ellas la ventana se reengancha como siempre
  (mismo nombre de tmux, y si falta, un shell) pero sin lanzar la IA.
- **Opciones de tmux (D4)**: ninguna ruta automática (recuperación al arrancar, salida 72, la
  recuperación SSH del Mac, `recovery.py` al crear) cambia opciones de servidor (`set-option -s`,
  `-g`) ni tablas de teclas (`bind-key`) si el servidor **ya existía**: solo `new-session -d`. Se
  sabe que no existía cuando `list-sessions` falla con `no server running` (o `error connecting`,
  `No such file`). Las opciones de la propia sesión recién creada (`-t <sesión>`) sí se ponen.
- **Interrumpida (D5)**: la ventana solo se marca interrumpida en un cierre anómalo (servidor tmux
  caído, o la sesión desaparecida de una lectura con `ausente_es_desaparecida` sin acción del usuario
  en UniConnect) y con una observación viva de su IA de como mucho **1 tick** (8 s en local, 60 s en
  SSH). Nunca al cerrar la ventana, al cerrar su tmux, ni cuando el shell del panel sale limpio.
  Interrumpida dice qué reanudar cuando la ventana **se vuelva a abrir**; que se recree sola la
  sesión remota lo decide aparte la regla de recuperación de arriba.

## `arbol-ejemplo.json`

El árbol en el cable, con las claves en inglés como el resto de contratos:
`{version, machine_id, platform, checked_at, workspaces: [{id, name, kind, host, host_label,
windows: [{id, name, state, tmux, agent}]}]}`.

- `window.state`: `agent`, `shell` o `stopped`.
- `tmux`: `{socket, session, session_id, pane_id, live}`. `session_id` y `pane_id` solo existen en
  vivo; los renumera tmux al reiniciar su servidor, así que nunca se persisten.
- `agent.state`: `activo`, `guardado` o `interrumpido`. `agent.history` va de la más antigua a la
  actual, ≤ 32 entradas.
- `resume` no viaja en el árbol: se deriva de `provider`, `session_id`, `cwd` y `as_root`, y la
  llamada de Detalles (`contracts/window-details-v1`) lo trae ya calculado.
- Las fechas van en ISO 8601 UTC (`Z`).
