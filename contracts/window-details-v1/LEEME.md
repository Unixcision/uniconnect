# Ejemplos normativos de `window_details.v1`

Estos ficheros **son el contrato**, no una ilustración. Si un ejemplo y una implementación
discrepan, manda el ejemplo. El modelo que hay detrás está en `docs/ARBOL-IA-v1.md`.

| Archivo | Qué fija |
|---|---|
| `details-request.json` | Forma de `mobile.terminal.details`. |
| `details-response-local.json` | Una ventana local del Mac con Claude en marcha. |
| `details-response-ssh.json` | Una ventana SSH con Claude como root: `IS_SANDBOX=1` en la orden. |
| `details-response-no-agent.json` | Una ventana SSH sin IA: `agent: null` y `reason: "sin_ia"`. |
| `errors.json` | Errores de la llamada, con cuándo salen y el mensaje en español. |

## Quién lee qué (a 24-09-2026)

| Archivo | Lo lee hoy | Tiene que leerlo |
|---|---|---|
| `details-response-*.json` | Android: `WindowDetailsContractTest` los pasa por `NativeMachineClient.decodeDetails` (`android/app/build.gradle.kts` los copia a los recursos de prueba). Escrito el 24-09-2026 sin ejecutarlo: Gradle está prohibido hasta nuevo aviso. | Las pruebas del RPC del Mac (`TerminalController`) y de `linux/uniconnect/mobile_rpc.py`. |
| `details-request.json`, `errors.json` | Nadie todavía. | Las mismas pruebas del Mac y de Linux. |

## Llamada

- Método `mobile.terminal.details`, y también `terminal.details`.
- El equipo anuncia `window_details.v1` en `capabilities` de `mobile.workspace.list`. Sin ella,
  Android no enseña la entrada «Detalles».
- Parámetros: `workspace_id` y `terminal_id`. Se acepta `surface_id` como alias de `terminal_id`; si
  vienen los dos y no coinciden, `invalid_params`.
- Es **solo lectura**: no persiste nada ni lanza nada. Tarda como mucho 10 s.
- Si la comprobación en vivo falla o vence, responde **con lo guardado**: `agent.state = "guardado"`
  y, si no había nada guardado, `reason: "host_inaccesible"`. Nunca un error por la sonda.

## Respuesta

Todas las claves están siempre; las que no aplican van `null`.

- `version`: 1. `checked_at`: cuándo se armó la respuesta, en ISO 8601 UTC (`Z`).
- `workspace`: `{name, kind, host, host_label}`. `kind` es `local` o `ssh`. En local, `host` y
  `host_label` son `null`. En SSH, `host` es `{user, hostname, port}` del destino efectivo; con la
  bóveda cerrada `host` va `null` y `host_label` sale del perfil. **Jamás** viajan la orden de
  conexión, contraseñas ni `credentialId`.
- `window`: `{name}`.
- `tmux`: `{socket, session, session_id, pane_id, live}`. `default` es el servidor por defecto.
  `session_id` y `pane_id` solo existen en vivo; si la sesión no está en marcha van `null` y
  `live: false`. Ventana antigua sin tmux: `tmux: null` y `reason: "sin_tmux"`.
- `agent`: `null` si no hay IA ni guardada ni en vivo. Si hay:
  `{provider, display_name, session_id, cwd, as_root, source, state, observed_at, resume}`.
  - `provider`: `claude`, `codex`, `agy`, `grok` u otro id de `agent-resume-v1.json`.
  - `session_id`: `null` si se detectó la IA sin id; entonces `resume` es `null` y
    `reason: "sin_id"`.
  - `source`: `ficha`, `rollout`, `argv`, `hook`, `manifiesto` o `registro`.
  - `state`: `activo` (confirmada ahora), `guardado` (lo último persistido, sin confirmar) o
    `interrumpido` (se reanudará al abrir).
  - `resume`: `{argv, environment, command, no_prompt_verified}`. Se deriva, nunca se persiste, y
    sale igual que en `contracts/agent-tree-v1/reanudar-comandos.json`.
- `reason`: `null`, `sin_ia`, `identidad_ambigua`, `sin_id`, `host_inaccesible` o `sin_tmux`.

## Errores

En el RPC viajan como siempre, `{code, message}`. `errors.json` da, por cada `code`, cuándo sale
(`cuando`) y el `mensaje` en español que pone el equipo en `message`.
