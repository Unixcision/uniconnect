# Árbol IA v1 (`agent-tree.v1`)

Un solo modelo para saber, en cada ventana de UniConnect, **qué tmux la sostiene y qué IA corre
dentro, con qué conversación**, y para volver a ponerla en marcha sin preguntas si el tmux se cae.
Vale igual para el Mac, Linux, Android y el supervisor de los VPS (`linux/scripts/recovery.py`).

Los ejemplos normativos están en `contracts/agent-tree-v1/`, `contracts/window-details-v1/` y
`contracts/relaunch-v1/`. Si este documento y un ejemplo discrepan, manda el ejemplo.

## 1. Qué se quiere (Dani, 24-09-2026)

- Todo espacio de trabajo sabe si es **local** o **VPS** (SSH, con su host).
- Cada ventana tiene su tmux y se apunta su socket y su sesión.
- Si dentro corre una IA (Claude Code, Codex, agy, grok…), se apunta cuál es y su conversación.
- Se relanza **siempre sin preguntas**: `IS_SANDBOX=1 claude --resume <id> --dangerously-skip-permissions`
  como root, `codex --yolo resume <id>`, y el equivalente de cada IA.
- «Guardar» persiste ese árbol entero. Si un tmux se cae, UniConnect lo recupera al abrirse: tmux e
  IA en su conversación. Igual en los VPS.
- Sirve a «Relanzar IA» de la ventana, del espacio y del equipo, en Mac, en Linux y desde Android.
- «Detalles» en el menú de cada ventana enseña todo esto (sección 9).

## 2. El árbol

```
equipo (machine_id, platform)
└── espacio   {id, nombre, tipo: local|ssh, host?: {user, hostname, port}, host_label?: "user@hostname:port"}
    └── ventana {id, nombre, estado: agent|shell|stopped}
        ├── tmux  {socket, sesion}                  ← identidad DURABLE (se persiste)
        │         {session_id "$N", pane_id "%N"}    ← solo EN VIVO (se lee, se enseña, nunca se persiste)
        └── ia    {proveedor, session_id, cwd, como_root, fuente, visto_en}
            ├── interrumpida  (la IA estaba activa cuando el tmux se cayó; ver 3.3)
            ├── historial[]   {proveedor, session_id, cwd, primera_vez, ultima_vez}  (≤32, solo se añade)
            └── reanudar      {argv, entorno, orden}  ← DERIVADO, nunca persistido
```

En el cable las claves van en inglés, como en el resto de contratos: ver
`contracts/agent-tree-v1/arbol-ejemplo.json`.

### Reglas del modelo

1. **Clave de unión entre plataformas**: (host efectivo o equipo local, socket tmux, nombre de
   sesión). Es lo que comparten la sesión del Mac, el `state.json` de Linux y el `manifest.json` del
   VPS. `$N` y `%N` los renumera tmux al reiniciar su servidor: solo se enseñan en Detalles.
2. **Proveedores en el cable**: `claude`, `codex`, `agy`, `grok`. Los demás del catálogo, con su id
   de `agent-resume-v1.json`. El Mac traduce `.antigravity` a `agy`. El nombre que se enseña sale
   del `displayName` del catálogo (`Claude Code`, `Codex`, `Antigravity`, `Grok`); ninguna
   plataforma lleva su propia tabla.
3. **session_id**: `[A-Za-z0-9_-]{1,160}`. En Claude y Codex es un UUID en minúsculas.
4. **fuente**: `ficha` (`~/.claude/sessions/<pid>.json`), `rollout` (rollout de Codex abierto),
   `argv` (línea de órdenes, puede estar desfasada), `hook`, `manifiesto` (supervisor VPS) o
   `registro` (solo lo guardado, sin confirmar ahora).
5. **Estado de la IA en el cable**: `activo` (confirmada en esta lectura), `guardado` (último valor
   persistido, sin confirmar) o `interrumpido` (se reanudará al abrir).
6. **`reanudar` no se persiste nunca.** Linux lo prohíbe (`StateStore.forbidden` incluye `argv` y
   `resume_command`) y el Mac descarta el argv capturado porque puede llevar secretos. Siempre se
   calcula con proveedor, session_id, cwd y como_root y la política `noPrompt` (sección 6).
7. **Sockets**. No se unifican: no se pueden mover sesiones vivas de un servidor tmux a otro. El
   árbol dice siempre cuál es, y cada socket tiene un solo dueño de su recuperación (sección 7).
   - Mac local: `uniconnect-local`, o `uniconnect-local-<sha8>` en builds con tag.
   - Linux local: `uniconnect-local`.
   - Mac SSH: `default`, el servidor por defecto (`-L default` es el mismo servidor).
   - Linux SSH: `record.tmuxSocket` o `uniconnect`.
   - VPS: `manifest.tmuxSocket` y la lista opcional `tmuxSockets`.
8. **cwd**: siempre resuelto con realpath. En el Mac, `~/Desktop/NOTBETTING` es `~/Developer/NOTBETTING`.
9. **como_root**: el uid del proceso raíz de la IA es 0. Solo decide si Claude lleva `IS_SANDBOX=1`.

### Dónde vive cada campo

| Campo | Mac local | Mac SSH | Linux (`state.json`) | VPS (`manifest.json`) | Cable |
|---|---|---|---|---|---|
| tipo/host | `Workspace.uniConnectProfile.kind` | `profile.kind` + credencial → `UniConnectSSHEffectiveTarget`; `profile.hostLabel` guardado ya como `usuario@host:puerto` | `workspace.kind` + `SSHCommand.endpoint_key()` resuelto con `ssh -G` fuera de GTK; `hostLabel` = `"user@host:port"` | el propio host | `workspace.kind/host/host_label` |
| nombre ventana | `record.visibleName` | título del panel | `record.name` | `entry.name` | `window.name` |
| tmux | `record.tmuxBinding.{socketName,name}` | `"default"` + `uniConnectTmuxSessionsByPanelId` | `record.tmuxSocket` + `record.tmux` | `entry.tmuxSocket` o `manifest.tmuxSocket` + `entry.tmux` | `tmux.socket/session` |
| IA activa | `record.conversations[activeConversationID]` | `SessionTerminalPanelSnapshot.uniConnectRemoteAgent` | `agent`, `sessionId`, `resumeCwd`, `asRoot`, `agentSource`, `agentObservedAt` | `agent`, `sessionId`, `cwd`, `source`, `asRoot` | `agent.*` |
| estado | `record.runtimeState` | `remoteAgent.runtimeState` | `record.runtimeState` | presencia en `windows` | `agent.state` |
| interrumpida | `record.interruptedConversationID` | se queda en `agent` | `record.interrupted: true` | el supervisor recrea siempre | `agent.state = "interrumpido"` |
| historial | `record.conversations` | `remoteAgent.history` (≤32) | `record.history` (+ `cwd`) | — | `agent.history` |

Todas las claves nuevas son **opcionales y aditivas**: los lectores antiguos las ignoran.

Registro SSH del Mac, persistido dentro del panel:

```json
{"version":1,"provider":"claude","sessionID":"473ed1de-4397-45ef-b00b-6b17fd7382b0","workingDirectory":"/root/xunis","asRoot":true,"tmuxSocket":"default","runtimeState":"agent","source":"ficha","observedAt":1790253004.0,
 "history":[{"provider":"claude","sessionID":"473ed1de-4397-45ef-b00b-6b17fd7382b0","workingDirectory":"/root/xunis","firstSeenAt":1790253004.0,"lastSeenAt":1790253004.0}]}
```

Entrada del manifiesto VPS:
`{"name","tmux","tmuxSocket"?,"agent","sessionId","cwd","workspace","source"?,"asRoot"?,"adopted"?,"tmuxOwner"?}`.
`adopted: true` marca una sesión aprendida que no creó el supervisor: nunca se le cambian opciones.

## 3. Detección: un solo criterio

Probado con `contracts/agent-tree-v1/deteccion-casos.json`, cuyo `LEEME.md` tiene el criterio
normativo completo. Resumen:

1. **Subárbol**: todos los descendientes de `pane_pid` (el **shell** del panel), en anchura sobre la
   tabla de procesos (profundidad ≤ 8, ≤ 256 nodos). Nunca `pgrep -P` ni el entorno heredado.
2. **Proveedor de cada proceso**, con un criterio estricto que la ficha no altera:
   - **claude**: basename(argv0) `claude`; o argv0 con `/claude/versions/`; o node/bun con un
     argumento que contiene `@anthropic-ai/claude-code` o cuyo basename es `claude`.
   - **codex**: basename(argv0) empieza por `codex`; o node/bun con `@openai/codex` o con un
     argumento de basename `codex`/`codex.js`.
   - **agy**: basename `agy` o `antigravity`. **grok**: basename `grok` o `grok-*`.
   - sudo, env, los shells, login, tmux, python y un node sin marca no son IA.
3. **Raíces**: procesos de proveedor sin antepasado de proveedor dentro del subárbol. 0 → `sin_ia`;
   2 o más → `identidad_ambigua` (no se toca nada guardado); 1 → esa IA. Con varios paneles en la
   sesión, cuenta el único panel con raíz; raíz en más de uno → `identidad_ambigua`.
4. **Identidad**, gana la primera fuente disponible:
   - **Claude**: ficha de la raíz si su `pid` interior coincide o no está (`ficha`) → `--resume`,
     `-r` o `--session-id` antes de `--`, con **un solo** valor válido (`argv`) → `sin_id`.
   - **Codex**: rollouts abiertos por la raíz y su rama. Uno → ese (`rollout`). Varios → solo el que
     coincide con `resume <uuid>` de argv, si no `sin_id`. Ninguno → `resume <uuid>` (`argv`) →
     `sin_id`. El cwd sale de `payload.cwd` del rollout elegido.
   - **agy**: `--conversation <id>`. **grok**: `-r` o `--resume <id>`. Las dos, `argv`.
   - **cwd**: el de la ficha o el rollout; si no, el del proceso; si tampoco, `pane_current_path`.
   - **como_root** = uid de la raíz == 0.

Ante la duda, no se da id: un `sin_id` deja lo guardado como estaba y un id equivocado reanuda otra
conversación. Las cuatro divergencias que encontró la revisión del 24-09 (`--`, dos ids en argv,
varios rollouts, `pid` de la ficha) se cerraron así; los casos y el porqué están en el `LEEME.md`
del contrato.

### 3.1 La sonda compartida

`linux/uniconnect/agent_probe.py` aplica el criterio en solo lectura (`list-panes`, `ps`, `/proc`,
`lsof`, lectura de fichas y de la primera línea del rollout; nunca `send-keys`, `set-option`, sudo ni
escritura en `~/.claude` o `~/.codex`). Su salida es exactamente
`contracts/agent-tree-v1/sonda-salida.json`: una entrada por **sesión** (`sessions`), ya agregada,
con el uid de quien sondea en `host.uid` y los errores `tmux_no_disponible`, `tmux_fallo` y
`sonda_fallo: <Tipo>`. Cómo se lee cada caso está en `sonda-lectura.json`.

- **Mac local**: Swift nativo en `Packages/CMUXAgentLaunch` (`AgentProcessDiscovery`), dentro de
  `UniConnectLocalTmuxService.runtimeObservations`, con sus guardas actuales.
- **Mac SSH**: `UniConnectRemoteAgentProbe` manda `agent_probe.py` por stdin (`python3 - --socket
  default`) por el mismo canal ssh de la caja, empaquetado como recurso del .app, y lo decodifica
  con `AgentProbeReport`. Una conexión por caja, ≤ 10 s, ≤ 256 KiB más el salto final.
- **Linux local y SSH**: `AgentTree` ejecuta el mismo script con `Transport.run`, con el arranque
  de `agent_identity_hook` (`python3 -c 'import base64,sys;…' <b64> --socket <s>`).
- **VPS**: `recovery.py` lleva **una copia** de las mismas funciones, porque se despliega solo y no
  puede importar. Se prueba con el mismo fixture.

### 3.2 Cuándo se refresca

| Momento | Mac local | Mac SSH | Linux | VPS |
|---|---|---|---|---|
| Periódico (el «tick») | cada 8 s | cada ≥ 60 s por caja con algún panel conectado | local cada 8 s; SSH cada 60 s por grupo con alguna superficie conectada | cada 15 s |
| Al abrir la app | primer tick | primer tick | primer tick | — |
| «Guardar» | espera a la reconciliación | refresco forzado, ≤ 10 s | `refresh_all` y luego persist (se guarda igual si la sonda falla) | — |
| «Detalles» | una observación del objetivo | sonda de esa caja, ≤ 8 s | sonda del grupo fuera del hilo GTK, ≤ 8 s | — |

Linux, igual que el Mac, solo sondea por SSH las cajas con alguna ventana conectada: sondear cada
60 s cajas guardadas sin ventanas abiertas abre conexiones a hosts caídos o sin usar.

### 3.3 Qué cambia en lo guardado

Solo se guarda si algo cambia. Por cada sesión de la sonda (`sonda-lectura.json`):

- **1 IA con id**: estado `agent` y esa IA pasa a activa. Si el id cambia tras `/clear` o `/resume`,
  entra la nueva y la vieja queda en el historial.
- **IA sin id**: no se toca la conversación guardada.
- **`sin_ia` de un panel vivo**: estado `shell`. La última IA queda en el historial y no se reanuda
  sola. Es el **único** caso que lleva a shell.
- **Ambigua, `panel_muerto` (o `live: false`), sesión ausente o sonda con error**: no se toca nada.
  Un panel muerto con `remain-on-exit` no dice que la IA se cerrara.
- **Interrumpida (D5)**: solo en un **cierre anómalo** y con una observación viva de esa IA de como
  mucho **1 tick** (8 s en local, 60 s en SSH):
  - cierre anómalo = el servidor tmux se cayó (la lectura del socket da `server: false` sin error,
    o el cliente enganchado terminó porque murió el servidor), o la sesión desapareció de una
    lectura completa (sin error ni `truncated`) sin que el usuario la cerrara desde UniConnect;
  - nunca desde «cerrar tmux» (`kill_tmux`), cerrar la ventana ni una salida limpia del shell del
    panel;
  - igual en Mac (`interruptedConversationID`) y en Linux (`interrupted: true`).
  Interrumpida dice qué reanudar cuando la ventana se vuelva a abrir. Que la sesión remota se
  recree sola lo decide aparte la sección 7.

## 4. Guarda de conversación abierta

Antes de toda reanudación automática se comprueba que la conversación **no** está abierta en otra
parte del mismo host. `linux/uniconnect/agent_guard.py` devuelve 0 (libre), 1 (abierta) o 2 (no se
puede comprobar); solo el 0 permite reanudar. Casos en `deteccion-casos.json` → `guarda`.

- **Claude**: existe una ficha con ese `sessionId` cuyo pid está vivo y **es Claude por el criterio
  estricto** de la sección 3 (un argumento que contiene `claude` no basta: `vim CLAUDE.md` con un
  pid reciclado no bloquea). La línea de órdenes no cuenta. La guarda local del Mac
  (`UniConnectClaudeOpenConversationGuard`) usa el mismo criterio.
- **Codex**: alguien tiene abierto su rollout o el cerrojo del kernel sobre
  `~/.codex/thread-writer-locks/<id>.lock`.
- **agy**: cerrojo sobre `~/.gemini/antigravity-cli/presence/<id>.lock`.
- **grok**: un grok vivo con ese id en su línea de órdenes.

## 5. Qué no hace nunca la detección

- No envía teclas, no cambia opciones de tmux, no mata procesos, no usa sudo.
- No escribe en `~/.claude` ni en `~/.codex`.
- No adivina: ambigua o sin id se enseña como tal y no pisa lo guardado.

## 6. Política única `noPrompt`

Vive en `Packages/CMUXAgentLaunch/Sources/CMUXAgentLaunch/Resources/agent-resume-v1.json`. La leen
el Mac (`AgentNoPromptPolicy`) y Linux (`AgentResumeCatalog.no_prompt` y el trabajador de
relanzado, que recibe el catálogo en la petición). `recovery.py` lleva una copia. Todas se prueban
con `contracts/agent-tree-v1/reanudar-comandos.json`, que desde el 24-09 trae también casos con
opciones conservadas (`arguments`).

- claude: `"noPrompt": {"suffix": ["--dangerously-skip-permissions"], "rootEnvironment": {"IS_SANDBOX": "1"}}`
- codex: `"noPrompt": {"prefix": ["--yolo"], "legacy": ["--dangerously-bypass-approvals-and-sandbox"],
  "supersedes": [-a, --ask-for-approval, -s, --sandbox (con valor), --full-auto]}` (D2). Codex
  rechaza `--yolo` junto a cualquiera de ellas: sin esto, un lanzamiento capturado con `-a never`
  reanudaría como `codex --yolo resume <id> -a never` y moriría en un shell.
- agy: `"noPrompt": {"prefix": ["--dangerously-skip-permissions"]}` (heredada; sin verificar en un binario real)
- grok: sin `noPrompt`. No hay binario real para verificar la bandera y no se inventa:
  `no_prompt_verified: false`.
- Cada proveedor lleva además `displayName`.

Aplicación, igual en las cuatro implementaciones (el `LEEME.md` del contrato la fija paso a paso):
argv = plantilla `resume` del catálogo con sus `{arguments}`. De `argv[1:]` se quitan las apariciones
de prefix, suffix y legacy, y cada bandera de `supersedes` con su valor (`-a never`, `-a=never`,
`--sandbox=…`). Después va prefix justo tras argv[0] y suffix al final, una vez.
`rootEnvironment` solo como root. Los lanzamientos nuevos del Mac salen también de esta política,
nunca con banderas escritas a mano.

| IA | orden de shell |
|---|---|
| Claude (root) | `cd -- '<cwd>' && IS_SANDBOX=1 claude --resume <id> --dangerously-skip-permissions` |
| Claude | `cd -- '<cwd>' && claude --resume <id> --dangerously-skip-permissions` |
| Codex | `cd -- '<cwd>' && codex --yolo resume <id>` |
| Codex con `-C`, `-a`, `--sandbox`, `--full-auto` y `-m` conservados | `cd -- '<cwd>' && codex --yolo resume <id> -C <cwd> -m <modelo>` |
| agy | `cd -- '<cwd>' && agy --dangerously-skip-permissions --conversation <id>` |
| grok | `cd -- '<cwd>' && grok -r <id>` |

- El cwd va siempre entre comillas simples POSIX (`'` → `'\''`).
- Un token de argv solo lleva comillas si tiene algo fuera de `[A-Za-z0-9@%_+=:,./-]`.
- Las opciones de ventana (codex `-C <cwd>`, `-m <modelo>`; claude `--model`) van detrás.
  `recovery.py` lanza `codex --yolo resume <id> -C <cwd> [-m M] [-c model_reasoning_effort=…]`.
- `IS_SANDBOX` en el destino: Linux y `recovery.py` lo deciden allí (`id -u` o `os.geteuid()`); el
  Mac en SSH con `asRoot` (o, si falta, usuario ssh `root`); el Mac local nunca es root.

## 7. Recuperación al abrir (tmux caído)

### 7.1 Quién recupera cada socket (D6)

Una sesión que falta la recrea **un solo dueño**, en su socket: el Mac las de sus ventanas (locales
en `uniconnect-local`, SSH en `default`), Linux las suyas (`uniconnect-local` y `record.tmuxSocket`
o `uniconnect`) y el supervisor VPS solo las entradas de su manifiesto, reconocidas por
`@uniconnect_session_id`/`tmuxOwner`. La tabla completa y el arbitraje cuando dos dueños coinciden
en socket y nombre están en `contracts/agent-tree-v1/LEEME.md`.

**Recuperación remota automática** (Mac SSH y Linux SSH): solo si la última lectura en vivo que vio
esa sesión tiene como mucho **2 ticks** (≤ 120 s) y no hay marca de cierre deliberado. Hay marca
cuando el usuario la cerró desde UniConnect y cuando una lectura del socket entero trae el servidor
vivo con otras sesiones y falta solo esta (la regla de `missing_is_deliberate`: alguien la cerró a
propósito, también si fue a mano en el VPS). Tras un reinicio largo del VPS la recrea el supervisor
si la tiene en su manifiesto; si no, se reabre a mano («Reabrir terminal»).

Estas condiciones deciden si se **reanuda la IA** sola. Sin ellas, la ventana se reengancha como
siempre (mismo nombre de tmux; si falta, se recrea con un shell, `docs/UNICONNECT-RECOVERY.md`), pero
sin lanzar la IA.

### 7.2 Opciones de tmux en caliente (D4)

Ninguna ruta automática (recuperación al arrancar y salida 72 en Linux, `recovery.py` al crear
sesiones, recuperación SSH del Mac) cambia opciones de servidor (`set-option -s`, `-g`) ni tablas de
teclas (`bind-key`) **si el servidor ya existía**: solo `new-session -d`. Se sabe que no existía
cuando `list-sessions` falla con `no server running`. Solo entonces se ponen las opciones de servidor
y las teclas. Las opciones de la sesión recién creada (`-t <sesión>`) se ponen siempre. Motivo: el
23-09 un `set-clipboard` en caliente mató el tmux del Mac con 27 IA dentro.

### 7.3 Por plataforma

- **Mac local**: `tmux new-session -A`. Si la sesión vive, solo se engancha. Si murió, se recrea con
  `zsh -ilc '<reanudar>; exec zsh -l'` cuando: estado `agent` (o `stopped` con
  `interruptedConversationID`), autoreanudar activo, la carpeta existe, ninguna otra ventana reclama
  la conversación y no está viva en otra parte. «Reabrir terminal» sigue la misma regla.
- **Mac SSH**: `remoteRecoverableTmuxCommand` recibe un `initialCommand` que tmux solo ejecuta si
  crea la sesión. tmux lo pasa al `default-shell` del VPS, que puede ser fish o tcsh, así que la
  línea va entera dentro de `/bin/sh -c '<línea>'` (con las comillas simples escapadas) y termina con
  una reserva que sí funciona:

  ```
  /bin/sh -c 'if cd -- '\''<cwd>'\'' && python3 -c '\''import base64,sys;s=sys.argv.pop(1);exec(base64.b64decode(s))'\'' <b64 de agent_guard.py> <proveedor> <id>; then [IS_SANDBOX=1 ]<argv>; else printf '\''%s\n'\'' '\''[UniConnect] No se reanuda: la conversación sigue abierta en otra ventana o falta la carpeta.'\''; fi; command -v bash >/dev/null && exec bash -l; exec sh -l'
  ```

  `exec bash -l || exec sh -l` no servía: un `exec` fallido termina un sh no interactivo. Sin `$` y
  sin `;` final. Sin python3 remoto no hay guarda y no se reanuda: queda un shell con el mensaje.
  Solo con `runtimeState == agent`, id válido, autoreanudar activo y las condiciones de 7.1.
- **Linux**: `SessionRecovery` es una operación aparte; reconectar sigue siendo solo enganchar. Se
  ejecuta al arrancar (sobre el estado leído del disco, antes de lanzar superficies) y cuando una
  superficie sale con 72. Nunca recrea ventanas cerradas por el usuario. Cumple 7.1 y 7.2.
- **VPS**: `recovery.py ensure` (cada 15 s con `supervise`) recrea las entradas del manifiesto con
  la misma orden. Su guarda es la ficha viva en Claude y el cerrojo del kernel en Codex y agy.
  `set-clipboard` solo se pone si el servidor no existía antes del `new-session`.

## 8. Relanzar

`docs/RELANZAR-v1.md` y `contracts/relaunch-v1/`. Desde el 24-09-2026 relanzar **siempre** reabre sin
preguntas (sustituye a «no cambiar lo que la IA puede hacer»). Una ventana sin IA sale con
`sin_ia`. Tras D7, el Mac y Linux relanzan Claude y Codex en ventanas locales, Linux también en
cajas SSH, y el Mac sigue con SSH en `no_soportado`; agy y grok, `no_soportado` en todos. Cada
equipo anuncia lo que sabe con `relaunch.v1.<proveedor>.<tipo>` (`contracts/relaunch-v1/proveedores.json`).

## 9. Detalles de una ventana

`contracts/window-details-v1/`. Entrada «Detalles…» en el menú contextual de la ventana (Mac y
Linux) y «Detalles» en el menú ⋮ del terminal en Android (`mobile.terminal.details`, capacidad
`window_details.v1`; en escritorio también `terminal.details` por el socket local). Enseña espacio,
local o VPS, ventana, socket y sesión tmux, sus ids en vivo, la IA, su estado, su conversación, la
carpeta, si va como root, de dónde sale el dato y la orden para reanudarla con «Copiar orden».

Decisiones del 24-09 (D3), fijadas con un ejemplo cada una:

- IA guardada y la ventana ahora en un shell: se enseña lo guardado (`state: "guardado"`) con
  `reason: "sin_ia"`.
- IA en marcha sin id: `session_id` y `source` a `null`.
- `host_label` siempre `usuario@host:puerto`; `host` es el destino efectivo resuelto; con la bóveda
  cerrada, `host: null` y `as_root` sale del usuario de `host_label`.
- Si la comprobación en vivo falla, `reason: "host_inaccesible"` aunque haya algo guardado, para que
  Android enseñe el mismo aviso que el escritorio.
- El texto de cada fila es literal y el mismo en Mac, Linux y Android: la tabla está en el
  `LEEME.md` del contrato y, por ejemplo, en `filas.json`.

## 10. Condiciones de seguridad

1. Solo se reanudan ids que la sonda vio o que se persistieron de una fuente verificada.
2. Nunca se reanuda una conversación abierta en otra parte del mismo host (guarda).
3. Nunca se sustituye una sesión tmux que existe (`new-session -A` o `has-session`).
4. La recuperación no envía teclas a paneles vivos ni cambia opciones de servidor ni teclas de un
   servidor tmux que ya existía (7.2).
5. Lo que el usuario cerró no resucita, tampoco lo que se mató a mano en el VPS (7.1).
6. Si falta la carpeta o la política no carga, se abre un shell con un mensaje en español.
7. En el Mac, sin autoreanudar se abre un shell.
8. Relanzar exige exactamente un proceso del proveedor, la política de cierre y el dialecto.
9. Solo se escribe en `~/.claude` o `~/.codex` lo que ya hacen los propios agentes. Excepción que
   queda como riesgo conocido: `recovery.py` conserva `trust_folder_for_claude`, que marca la carpeta
   como de confianza en `~/.claude.json` antes de reanudar.

## 11. Estado a 24-09-2026 (rama `integracion/arbol-ia`)

Lo que está en el repositorio y lo que no. Un apartado de este documento no es código.

| Pieza | Estado |
|---|---|
| `contracts/agent-tree-v1/`, `window-details-v1/` y `relaunch-v1/` | Cerrados con las decisiones D1–D8 del 24-09. Los casos nuevos fallan en al menos una implementación hasta que se alineen; es lo esperado. |
| `linux/uniconnect/agent_probe.py`, `agent_guard.py`, `AgentTree`, `SessionRecovery`, `window_details.py` | Existen. Pendiente de alinear con D1–D7 (detección, `supersedes`, opciones en caliente, interrumpida, `source`/`host`/`display_name` en Detalles, dialecto de Claude). |
| `linux/scripts/recovery.py` | Existe y pasaba todos los casos anteriores. Pendiente de alinear con los casos nuevos, `supersedes` y el `set-clipboard` solo en servidor nuevo. No desplegado en ningún VPS. |
| `AgentProcessDiscovery`, `AgentNoPromptPolicy`, `AgentProbeReport`, `UniConnectRemoteAgentProbe`, modal «Detalles» del Mac | Existen. Pendiente de alinear con D1–D8 (lectura de `sessions`, panel muerto, `supersedes` y `displayName`, detección, Detalles, dialecto de Codex, ruta de los tests de contrato). |
| Android: «Detalles» y «Relanzar IA de esta ventana» en el ⋮, seguimiento de `en_curso` | Escrito; sin compilar ni ejecutar. Pendiente: textos de `filas.json` y tokens `relaunch.v1.<proveedor>.<tipo>`. |
| `noPrompt` con `supersedes` y `displayName` en `agent-resume-v1.json` | Pendiente (lo edita el Mac); los validadores de catálogo de Swift y de Linux tienen que aceptar las dos claves. |
