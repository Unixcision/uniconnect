# Árbol IA v1 (`agent-tree.v1`)

Un solo modelo para saber, en cada ventana de UniConnect, **qué tmux la sostiene y qué IA corre
dentro, con qué conversación**, y para volver a ponerla en marcha sin preguntas si el tmux se cae.
Vale igual para el Mac, Linux, Android y el supervisor de los VPS (`linux/scripts/recovery.py`).

Los ejemplos normativos están en `contracts/agent-tree-v1/` y `contracts/window-details-v1/`. Si este
documento y un ejemplo discrepan, manda el ejemplo.

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
            ├── interrumpida  (la IA estaba activa cuando murió el tmux o su cliente)
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
   de `agent-resume-v1.json`. El Mac traduce `.antigravity` a `agy`.
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
   árbol dice siempre cuál es.
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
| tipo/host | `Workspace.uniConnectProfile.kind` | `profile.kind` + credencial → `UniConnectSSHEffectiveTarget` + `profile.hostLabel` | `workspace.kind` + `SSHCommand.endpoint_key()`; `hostLabel` = `"user@host:port"` | el propio host | `workspace.kind/host/host_label` |
| nombre ventana | `record.visibleName` | título del panel | `record.name` | `entry.name` | `window.name` |
| tmux | `record.tmuxBinding.{socketName,name}` | `"default"` + `uniConnectTmuxSessionsByPanelId` | `record.tmuxSocket` + `record.tmux` | `entry.tmuxSocket` o `manifest.tmuxSocket` + `entry.tmux` | `tmux.socket/session` |
| IA activa | `record.conversations[activeConversationID]` | `SessionTerminalPanelSnapshot.uniConnectRemoteAgent` (nuevo) | `agent`, `sessionId`, `resumeCwd`, `asRoot`, `agentSource`, `agentObservedAt` | `agent`, `sessionId`, `cwd`, `source`, `asRoot` | `agent.*` |
| estado | `record.runtimeState` | `remoteAgent.runtimeState` | `record.runtimeState` | presencia en `windows` | `agent.state` |
| interrumpida | `record.interruptedConversationID` (nuevo, opcional) | se queda en `agent` | `record.interrupted: true` | el supervisor recrea siempre | `agent.state = "interrumpido"` |
| historial | `record.conversations` | `remoteAgent.history` (≤32) | `record.history` (+ `cwd`) | — | `agent.history` |

Todas las claves nuevas son **opcionales y aditivas**: los lectores antiguos las ignoran.

Registro SSH del Mac, persistido dentro del panel:

```json
{"version":1,"provider":"claude","sessionID":"473ed1de-4397-45ef-b00b-6b17fd7382b0","workingDirectory":"/root/xunis","asRoot":true,"tmuxSocket":"default","runtimeState":"agent","source":"ficha","observedAt":1790253004.0,
 "history":[{"provider":"claude","sessionID":"473ed1de-4397-45ef-b00b-6b17fd7382b0","workingDirectory":"/root/xunis","firstSeenAt":1790253004.0,"lastSeenAt":1790253004.0}]}
```

Entrada del manifiesto VPS:
`{"name","tmux","tmuxSocket"?,"agent","sessionId","cwd","workspace","source"?,"asRoot"?,"adopted"?}`.
`adopted: true` marca una sesión aprendida que no creó el supervisor: nunca se le cambian opciones.

## 3. Detección: un solo criterio

Probado con `contracts/agent-tree-v1/deteccion-casos.json`. Entrada por panel: `pane_pid` (el
**shell** del panel, no la IA), la tabla de procesos `{pid, ppid, uid, argv}`, las fichas de Claude
por pid y los ficheros abiertos por pid.

1. **Subárbol**: todos los descendientes de `pane_pid`, en anchura sobre la tabla de
   `ps -eo pid=,ppid=,uid=,args=` o /proc (profundidad ≤ 8, ≤ 256 nodos).
   - Nunca `pgrep -P`: en macOS excluye a los ancestros del propio pgrep.
   - Nunca por entorno heredado: un proceso de fuera del subárbol no cuenta aunque lleve
     `CMUX_SURFACE_ID` o `TMUX` de la ventana (el Terminal.app que se hacía pasar por una ventana).
2. **Proveedor de cada proceso**:
   - **claude**: basename(argv0) `claude`; o node/bun con `@anthropic-ai/claude-code`; o argv0 bajo
     `.local/share/claude/versions/`; o tiene ficha y algún argumento contiene `claude`.
   - **codex**: basename(argv0) empieza por `codex` (incluye `codex-x86_64-unknown-linux-musl`); o
     node/bun con `@openai/codex` o con un argumento de basename `codex`/`codex.js`.
   - **agy**: basename `agy` o `antigravity`. **grok**: basename `grok` o `grok-*`.
   - sudo, env, sh, bash, zsh, fish, login y un node sin marca no son IA.
3. **Raíces**: procesos de proveedor sin antepasado de proveedor dentro del subárbol. Un codex que
   lanza la herramienta Bash de Claude no es raíz, ni el binario nativo de Codex bajo su lanzador.
   - 0 raíces → `sin_ia`. 2 o más → `identidad_ambigua` (no se toca nada guardado). 1 → esa IA.
   - Con varios paneles en la sesión, cuenta el único panel con raíz; raíz en más de uno →
     `identidad_ambigua`.
4. **Identidad**, gana la primera fuente disponible:
   - **Claude**: ficha de la raíz (`ficha`; solo si el pid está vivo y su argv es de Claude, para
     descartar un pid reciclado; si la raíz es de uid 0 y quien sondea no, se prueba
     `/root/.claude/sessions` si se deja leer, nunca con sudo) → `--resume`, `-r` o `--session-id`
     (`argv`, menos fiable: miente tras `/clear` o `/resume`) → nada (`sin_id`).
   - **Codex**: un `rollout-*-<uuid>.jsonl` bajo `/.codex/sessions/` abierto por la raíz o por un
     codex de su rama (último UUID del nombre, `rollout`; en Linux con `readlink /proc/<pid>/fd/*`,
     en macOS con `lsof -n -P -p <pid> -Fn`); el cwd sale de `payload.cwd` de su primera línea
     (≤ 64 KB) → `resume <uuid>` (`argv`) → nada (`sin_id`).
   - **agy**: `--conversation <id>` (`argv`). **grok**: `-r` o `--resume <id>` (`argv`).
   - **cwd**: el de la ficha o el rollout; si no, el del proceso; si tampoco, `pane_current_path`.
   - **como_root** = uid de la raíz == 0.

### La sonda compartida

`linux/uniconnect/agent_probe.py` implementa este criterio en solo lectura (`list-panes`, `ps`,
`/proc`, `lsof`, lectura de fichas y de la primera línea del rollout; nunca `send-keys`,
`set-option`, sudo ni escritura en `~/.claude` o `~/.codex`). Su salida es
`contracts/agent-tree-v1/sonda-salida.json`.

- **Mac local**: Swift nativo en `Packages/CMUXAgentLaunch` (`AgentProcessDiscovery`), dentro de
  `UniConnectLocalTmuxService.runtimeObservations`, con sus guardas actuales.
- **Mac SSH**: `UniConnectRemoteAgentProbe` manda `agent_probe.py` por stdin (`python3 - --socket
  default`) por el mismo canal ssh de la caja. El script va empaquetado como recurso del .app.
  Una conexión por caja, ≤ 10 s, ≤ 256 KB.
- **Linux local y SSH**: `AgentTree` ejecuta el mismo script con `Transport.run`, con el arranque
  de `agent_identity_hook` (`python3 -c 'import base64,sys;…' <b64> --socket <s>`).
- **VPS**: `recovery.py` lleva **una copia** de las mismas funciones, porque se despliega solo y no
  puede importar. Se prueba con el mismo fixture.

### Cuándo se refresca y cuándo se guarda

| Momento | Mac local | Mac SSH | Linux | VPS |
|---|---|---|---|---|
| Periódico | cada 8 s | cada ≥ 60 s por caja con algún panel conectado | local cada 8 s; SSH cada 60 s por grupo | cada 15 s |
| Al abrir la app | primer tick | primer tick | primer tick, en todas las cajas | — |
| «Guardar» | espera a la reconciliación | refresco forzado, ≤ 10 s | `refresh_all` y luego persist (se guarda igual si la sonda falla) | — |
| «Detalles» | una observación del objetivo | sonda de esa caja, ≤ 8 s | sonda del grupo fuera del hilo GTK, ≤ 8 s | — |

Solo se guarda si algo cambia. Transiciones:

- **1 IA con id**: estado `agent` y esa IA pasa a activa. Si el id cambia tras `/clear` o `/resume`,
  entra la nueva y la vieja queda en el historial.
- **IA sin id**: no se toca la conversación guardada.
- **Shell sin hijos**: estado `shell`. La última IA queda en el historial y no se reanuda sola.
- **Ambigua, panel muerto, sesión ausente o sonda caída**: no se toca nada.
- **El cliente tmux sale con la IA activa**: `stopped` + interrumpida. Al volver a abrir se reanuda.

## 4. Guarda de conversación abierta

Antes de toda reanudación automática se comprueba que la conversación **no** está abierta en otra
parte del mismo host. `linux/uniconnect/agent_guard.py` devuelve 0 (libre), 1 (abierta) o 2 (no se
puede comprobar); solo el 0 permite reanudar. Casos en `deteccion-casos.json` → `guarda`.

- **Claude**: existe una ficha con ese `sessionId` cuyo pid está vivo y es Claude. La línea de
  órdenes no cuenta.
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
el Mac (`AgentNoPromptPolicy`) y Linux (`AgentResumeCatalog.no_prompt`). `recovery.py` lleva una
copia. Las tres se prueban con `contracts/agent-tree-v1/reanudar-comandos.json`.

- claude: `"noPrompt": {"suffix": ["--dangerously-skip-permissions"], "rootEnvironment": {"IS_SANDBOX": "1"}}`
- codex: `"noPrompt": {"prefix": ["--yolo"], "legacy": ["--dangerously-bypass-approvals-and-sandbox"]}`
- agy: `"noPrompt": {"prefix": ["--dangerously-skip-permissions"]}` (heredada; sin verificar en un binario real)
- grok: sin `noPrompt`. No hay binario real para verificar la bandera y no se inventa:
  `no_prompt_verified: false`.

Aplicación: argv = plantilla `resume` del catálogo. Se quitan las apariciones previas de prefix,
suffix y legacy, se inserta prefix justo después de argv[0] y se añade suffix al final, una vez.
`rootEnvironment` solo como root.

| IA | orden de shell |
|---|---|
| Claude (root) | `cd -- '<cwd>' && IS_SANDBOX=1 claude --resume <id> --dangerously-skip-permissions` |
| Claude | `cd -- '<cwd>' && claude --resume <id> --dangerously-skip-permissions` |
| Codex | `cd -- '<cwd>' && codex --yolo resume <id>` |
| agy | `cd -- '<cwd>' && agy --dangerously-skip-permissions --conversation <id>` |
| grok | `cd -- '<cwd>' && grok -r <id>` |

- El cwd va siempre entre comillas simples POSIX (`'` → `'\''`).
- Un token de argv solo lleva comillas si tiene algo fuera de `[A-Za-z0-9@%_+=:,./-]`.
- Las opciones de ventana (codex `-C <cwd>`, `-m <modelo>`; claude `--model`) van detrás.
  `recovery.py` lanza `codex --yolo resume <id> -C <cwd> [-m M] [-c model_reasoning_effort=…]`.
- `IS_SANDBOX` en el destino: Linux y `recovery.py` lo deciden allí (`id -u` o `os.geteuid()`); el
  Mac en SSH con `asRoot` (o, si falta, usuario ssh `root`); el Mac local nunca es root.

## 7. Recuperación al abrir (tmux caído)

- **Mac local**: `tmux new-session -A`. Si la sesión vive, solo se engancha. Si murió, se recrea con
  `zsh -ilc '<reanudar>; exec zsh -l'` cuando: estado `agent` (o `stopped` con
  `interruptedConversationID`), autoreanudar activo, la carpeta existe, ninguna otra ventana reclama
  la conversación y no está viva en otra parte. «Reabrir terminal» sigue la misma regla.
- **Mac SSH**: `remoteRecoverableTmuxCommand` recibe un `initialCommand` que tmux solo ejecuta si
  crea la sesión. Lleva la guarda remota delante y, si no pasa, deja un shell con el mensaje
  «[UniConnect] No se reanuda: la conversación sigue abierta en otra ventana o falta la carpeta.».
  Sin `$` y sin `;` final. Sin python3 remoto no hay guarda y no se reanuda.
- **Linux**: `SessionRecovery` es una operación aparte; reconectar sigue siendo solo enganchar. Se
  ejecuta al arrancar (sobre el estado leído del disco, antes de lanzar superficies) y cuando una
  superficie sale con 72. Nunca recrea ventanas cerradas por el usuario.
- **VPS**: `recovery.py ensure` (cada 15 s con `supervise`) recrea las entradas del manifiesto con
  la misma orden. Su guarda es la ficha viva en Claude y el cerrojo del kernel en Codex y agy.

## 8. Relanzar

`docs/RELANZAR-v1.md` y `contracts/relaunch-v1/`. Desde el 24-09-2026 relanzar **siempre** reabre sin
preguntas (sustituye a «no cambiar lo que la IA puede hacer»). Una ventana sin IA sale con
`sin_ia`; SSH sigue `no_soportado`.

## 9. Detalles de una ventana

`contracts/window-details-v1/`. Entrada «Detalles…» en el menú contextual de la ventana (Mac y
Linux) y en el menú ⋮ del terminal en Android (`mobile.terminal.details`, capacidad
`window_details.v1`). Enseña espacio, local o VPS, ventana, socket y sesión tmux, sus ids en vivo,
la IA, su estado, su conversación, la carpeta, si va como root, de dónde sale el dato y la orden
para reanudarla con «Copiar orden».

## 10. Condiciones de seguridad

1. Solo se reanudan ids que la sonda vio o que se persistieron de una fuente verificada.
2. Nunca se reanuda una conversación abierta en otra parte del mismo host (guarda).
3. Nunca se sustituye una sesión tmux que existe (`new-session -A` o `has-session`).
4. La recuperación no envía teclas a paneles vivos ni cambia opciones de sesiones o servidores
   existentes. `recovery.py` ya no hace `set-clipboard` en caliente en cada vuelta: solo al crear.
5. Lo que el usuario cerró no resucita.
6. Si falta la carpeta o la política no carga, se abre un shell con un mensaje en español.
7. En el Mac, sin autoreanudar se abre un shell.
8. Relanzar exige exactamente un proceso del proveedor, la política de cierre y el dialecto.
9. Solo se escribe en `~/.claude` o `~/.codex` lo que ya hacen los propios agentes. Excepción que
   queda como riesgo conocido: `recovery.py` conserva `trust_folder_for_claude`, que marca la carpeta
   como de confianza en `~/.claude.json` antes de reanudar.
