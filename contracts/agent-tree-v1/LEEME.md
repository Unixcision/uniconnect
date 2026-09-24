# Ejemplos normativos de `agent-tree.v1`

Estos ficheros **son el contrato**, no una ilustración. Si un ejemplo y una implementación
discrepan, manda el ejemplo. El documento que los explica es `docs/ARBOL-IA-v1.md`.

| Archivo | Qué fija |
|---|---|
| `deteccion-casos.json` | El criterio común de detección (qué IA hay en un panel y con qué conversación) y la guarda de conversación abierta. |
| `reanudar-comandos.json` | La orden exacta con la que se reanuda cada IA, siempre sin preguntas. |
| `sonda-salida.json` | La salida v1 de `linux/uniconnect/agent_probe.py`, la sonda que comparten Linux, el Mac en SSH y el supervisor VPS. |
| `arbol-ejemplo.json` | El árbol de un equipo en el cable: un espacio local y uno SSH. |

## Quién lee qué (a 24-09-2026)

Solo se apunta aquí lo que existe en el repositorio. Lo que está en camino va en su propia columna.

| Archivo | Lo lee hoy | Tiene que leerlo |
|---|---|---|
| `deteccion-casos.json` | `linux/tests/test_recovery_v2.py`: todos los casos contra `detect_agent` y `guard` de `linux/scripts/recovery.py`. | Las pruebas de `AgentProcessDiscovery` (Mac) y las de `agent_probe.py` y `agent_guard.py` (Linux). |
| `reanudar-comandos.json` | `linux/tests/test_recovery_v2.py`: contra `canonical_resume` y `command_for` de `recovery.py`. | `AgentNoPromptPolicy` (Mac) y `AgentResumeCatalog.no_prompt` (Linux). |
| `sonda-salida.json` | Nadie todavía. | El decodificador de `UniConnectRemoteAgentProbe` (Mac SSH) y `AgentTree` (Linux). |
| `arbol-ejemplo.json` | Nadie todavía. | Referencia de forma; ninguna llamada lo devuelve entero hoy. |

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
  **nunca** mira el entorno: el caso 14 existe para probarlo.
- `fichas`: el contenido de `~/.claude/sessions/<pid>.json`, indexado por pid. El arnés la sirve
  donde la buscaría la implementación: en `/root/.claude/sessions/<pid>.json` si el proceso es de
  uid 0, y en `<home>/.claude/sessions/<pid>.json` en los demás casos. Así el caso 4 solo se acierta
  si la implementación busca también en /root cuando la raíz es de root.
- `abiertos`: los ficheros que tiene abiertos cada pid (`readlink /proc/<pid>/fd/*` en Linux;
  `lsof -n -P -p <pid> -Fn` en macOS).
- `rollouts`: la **primera línea** de cada rollout de Codex, tal cual, como texto JSON.
- `cwds`: el cwd de cada proceso (`/proc/<pid>/cwd`, o `lsof -a -p <pid> -d cwd -Fn`). Opcional.
- `enlaces`: rutas que son enlaces simbólicos y su destino real, por coincidencia exacta. El arnés
  resuelve con esto; cualquier otra ruta ya es real. Opcional.
- `pane_current_path`: el último recurso para el cwd. Opcional.

`espera` tiene dos formas:

- IA identificada: `{provider, session_id, cwd, as_root, source}`.
- IA detectada sin id: lo mismo con `session_id: null`, `source: null` y `cause: "sin_id"`.
- Sin IA o ambigua: `{cause: "sin_ia"}` o `{cause: "identidad_ambigua"}`.

**Se comparan solo las claves que trae `espera`.** Una implementación puede devolver más
(el pid de la raíz, `status`, `version`), pero no puede contradecir ninguna de las que están.

### Reglas que el fixture fija y conviene tener delante

1. El subárbol se recorre en anchura desde `pane_pid` (profundidad ≤ 8, ≤ 256 nodos). Nunca con
   `pgrep -P`, que en macOS excluye a los ancestros del propio pgrep.
2. Proveedores:
   - **claude**: basename(argv0) es `claude`; o node/bun con un argumento que contiene
     `@anthropic-ai/claude-code`; o argv0 bajo `.local/share/claude/versions/`; o existe su ficha
     **y** algún argumento contiene `claude`. Una ficha sola no hace Claude a un proceso: su pid
     puede estar reciclado (caso 13).
   - **codex**: basename(argv0) empieza por `codex` (incluye `codex-x86_64-unknown-linux-musl`); o
     node/bun con un argumento que contiene `@openai/codex` o cuyo basename es `codex` o `codex.js`.
   - **agy**: basename `agy` o `antigravity`.
   - **grok**: basename `grok` o que empieza por `grok-`.
   - sudo, env, los shells, login y un node sin marca no son IA. Sus descendientes ya están en el
     subárbol.
3. Raíz = proceso de proveedor sin antepasado de proveedor **dentro del subárbol**. 0 raíces:
   `sin_ia`. 2 o más: `identidad_ambigua`. Exactamente 1: esa IA.
4. Identidad, gana la primera fuente disponible:
   - Claude: ficha de la raíz (`ficha`) → `--resume`, `-r` o `--session-id` (`argv`) → `sin_id`.
   - Codex: rollout `rollout-*-<uuid>.jsonl` bajo `/.codex/sessions/` abierto por la raíz o por un
     codex de su rama; vale el **último** UUID del nombre (`rollout`) → `resume <uuid>` (`argv`) →
     `sin_id`. El cwd sale de `payload.cwd` de la primera línea.
   - agy: `--conversation <id>` (`argv`). grok: `-r` o `--resume <id>` (`argv`).
   - cwd: el de la ficha o el rollout; si no hay, el del proceso raíz; si tampoco, `pane_current_path`.
     Siempre resuelto (`enlaces`).
   - `as_root`: uid de la raíz == 0.

### Un caso de guarda

La guarda decide si una conversación se puede reanudar automáticamente. Devuelve **0** si está libre,
**1** si está abierta en otra parte y **2** si no se puede comprobar. Solo el 0 permite reanudar.

- `fichas_vivas`: las fichas que hay en disco, por pid. Que ese pid siga vivo lo dice `procesos`.
- `procesos`: los procesos vivos, con `{pid, argv}`.
- `abiertos`: ficheros abiertos por pid. `cerrojos`: rutas sobre las que alguien tiene el cerrojo
  del kernel (`/proc/locks` o `flock`).
- `proc_legible: false` simula que no se pueden leer los ficheros abiertos de los procesos.

Reglas:

- id que no cumple `[A-Za-z0-9_-]{1,160}` o proveedor desconocido: 2.
- claude: 1 si hay una ficha con ese `sessionId` cuyo pid está vivo y su argv es de Claude. La
  línea de órdenes no cuenta: tras `/clear` miente (caso `claude_argv_viejo_no_bloquea`).
- codex: 1 si algún proceso tiene abierto su `rollout-*-<id>.jsonl` o alguien tiene el cerrojo de
  `~/.codex/thread-writer-locks/<id>.lock`. 2 si no se pueden leer los abiertos.
- agy: 1 si alguien tiene el cerrojo de `~/.gemini/antigravity-cli/presence/<id>.lock` o un agy vivo
  lleva ese id en su línea de órdenes.
- grok: 1 si un grok vivo lleva ese id en su línea de órdenes. No hay otra fuente.

## `reanudar-comandos.json`

`{version: 1, casos: [{nombre, provider, session_id, cwd, as_root, argv, environment, command, no_prompt_verified}]}`

- `argv` es la forma canónica, sin opciones de ventana (`-C`, `-m`, `--model`): esas van detrás,
  dentro de `{arguments}` del catálogo, y no forman parte de este contrato.
- `environment` solo lleva `IS_SANDBOX=1`, y solo en Claude como root.
- `command` es la orden de shell: `cd -- '<cwd>' && [K=V ]<argv>`. El cwd va siempre entre comillas
  simples POSIX (`'` → `'\''`). Un token de argv solo lleva comillas si tiene algo fuera de
  `[A-Za-z0-9@%_+=:,./-]`.
- `no_prompt_verified` es `true` cuando el proveedor tiene política `noPrompt` en
  `Packages/CMUXAgentLaunch/Sources/CMUXAgentLaunch/Resources/agent-resume-v1.json`. Grok no la
  tiene: se reanuda con su sintaxis y `false`. La de agy se hereda de `recovery.py` y de
  `AgentResumeArgv`; no se ha comprobado contra un binario real.

## `sonda-salida.json`

`{version, host, uid, user, socket, error, panes: [...]}`. Cada panel:
`{session, session_id, window_index, pane_id, pane_pid, pane_dead, pane_current_path,
pane_current_command, agent, cause}`.

- `agent`: `{provider, session_id, cwd, as_root, source, pid, status, version}` o `null`.
  `status` y `version` salen de la ficha de Claude; en los demás, `null`.
- `cause`: `null`, `sin_id` (con `agent` y `session_id: null`), `sin_ia` o `identidad_ambigua`
  (las dos con `agent: null`).
- Un panel muerto (`pane_dead: true`) no se sondea: `agent` y `cause` van `null`.
- `error`: `null`, `sin_tmux` (no hay tmux), `sin_servidor` (no hay servidor en ese socket; `panes`
  vacío) o `fallo_tmux` (tmux respondió con error). Con error, `panes` va vacío y quien lee **no toca
  nada guardado**.
- La sonda informa **por panel**. Quien la lee agrega por sesión: cuenta el único panel con IA; si
  hay IA en más de uno, la sesión es `identidad_ambigua`.
- Límites: ≤ 10 s por llamada y ≤ 256 KB de salida.

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
