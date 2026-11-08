# `log.v1`: historial de UniConnect (Mac y Linux)

Un solo historial por equipo con lo que importa para entender un fallo: relanzados,
reconexiones, el móvil, la actividad y los errores de la interfaz. Lo escriben igual el Mac y
Linux, para que un mismo lector (persona, IA o el informe de diagnóstico) sirva en los dos.

## Dónde
- Mac: `~/.uniconnect/logs/uniconnect.jsonl`.
- Linux: `~/.uniconnect/logs/uniconnect.jsonl` del usuario que ejecuta la app (hoy root:
  `/root/.uniconnect/logs/uniconnect.jsonl`).
- Permisos: carpeta `0700`, ficheros `0600`.

## Rotación
- Al pasar de **5 MiB**, se renombra en cascada: `uniconnect.jsonl` → `.1` → … → `.4`, y se
  borra lo que pasaría de `.4`.
- Total máximo: unos 25 MiB por equipo.
- Se comprueba antes de cada escritura. Rotar nunca bloquea a quien registra: si falla, se sigue
  escribiendo en el actual y se deja una línea `log.rotate_failed`.

## Formato
Una línea JSON por evento (JSON Lines, UTF-8, sin saltos dentro).

| Campo | Tipo | Obligatorio | Qué es |
|---|---|---|---|
| `ts` | string | sí | Hora UTC en ISO 8601 con milisegundos: `2026-11-08T13:05:12.345Z`. |
| `level` | string | sí | `debug`, `info`, `warn` o `error`. |
| `area` | string | sí | `relaunch`, `reconnect`, `mobile`, `activity`, `tree`, `ui`, `retention`, `update`, `log`. |
| `event` | string | sí | Qué pasó, en `minúsculas.con_puntos`: `relaunch.exit_timeout`, `mobile.subscribe`. |
| `platform` | string | sí | `macos` o `linux`. |
| `version` | string | sí | Versión y commit de la app: `0.1.0+3e7e0922eb`. |
| `workspace` | string | no | Id del espacio afectado. |
| `window` | string | no | Id de la ventana afectada. |
| `op` | string | no | Id de la operación (por ejemplo, el `operation_id` de un relanzado), para seguirla de principio a fin. |
| `detail` | objeto | no | Datos propios del evento, planos y cortos (ver «Qué nunca»). |

Campos desconocidos: quien lee los ignora. Quien escribe no inventa campos de primer nivel: lo
específico va en `detail`.

## Niveles y depuración en caliente
- `info`, `warn` y `error` se escriben siempre.
- `debug` solo si el modo depuración está encendido. Se enciende y se apaga **sin reiniciar**:
  - Mac: el ajuste «Registro detallado» (UserDefaults `uniconnect.log.debug`), observado en vivo.
  - Linux: el ajuste equivalente en `state.json` (`log_debug`), observado en vivo.
- Al cambiar el modo se escribe `log.debug_on` / `log.debug_off` (nivel `info`).
- El modo se apaga solo a las **24 h** de encenderlo, para que nadie lo olvide encendido. Al
  apagarse se escribe `log.debug_off` con `detail.reason = "timeout"`.

## Qué se registra como mínimo (`info` salvo que se diga)
- **relaunch:** `relaunch.plan`, `relaunch.apply`, y por ventana:
  - `relaunch.exit_sent`, `relaunch.exit_timeout` (`warn`);
  - `relaunch.kill_process` (`warn`), `relaunch.kill_session` (`warn`);
  - `relaunch.session_recreated`, `relaunch.resumed`;
  - `relaunch.failed` (`error`, con `detail.cause` de `relaunch-v1/causes.json`);
  - `relaunch.excluded`, con `detail.cause`.
- **reconnect:** `reconnect.start`, `reconnect.ok`, `reconnect.failed` (`warn`, con `detail.cause`).
- **mobile:** `mobile.connect`, `mobile.disconnect` (con `detail.reason`), `mobile.subscribe`
  (`detail.topics`, `detail.surfaces` = número), `mobile.queue_overflow` (`warn`), y
  `mobile.rpc_error` (`warn`, con `detail.method` y `detail.code`).
- **activity:** solo en `debug`, nunca en `info`, porque es de alta frecuencia. Cada cambio de
  estado de una ventana con `detail.from`, `detail.to` y `detail.source`.
- **tree:** `tree.saved` (`debug`), `tree.resume` y `tree.resume_failed` (`warn`).
- **ui:** `ui.action_failed` (`warn`): cualquier acción de menú que no pudo hacerse, con
  `detail.action` y `detail.cause`. Ningún fallo de menú queda sin línea.
- **retention:** `retention.pass` con `detail.compressed` y `detail.deleted`.

## Qué nunca
- Nunca texto de la pantalla ni de la terminal, ni nada que el usuario haya escrito o dictado.
- Nunca argv ni entorno completos. Las opciones de lanzamiento se registran como en
  `agent-tree-v1`: solo las banderas conocidas y sin valores secretos.
- Nunca tokens, contraseñas, claves de API, cabeceras de autenticación ni contenido de prompts.
- Nunca rutas de conversación con contenido; sí el id de la conversación.
- Si un valor puede contener algo de lo anterior, no se registra: se registra su longitud
  (`detail.length`).

## Ejemplo
`ejemplo.jsonl` tiene un relanzado que escala hasta recrear la sesión, una reconexión fallida y
un ciclo de depuración. Un lector de `log.v1` tiene que poder leerlo entero.
