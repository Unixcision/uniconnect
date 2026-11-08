# `box-close.v1`: cerrar una ventana o un espacio desde el móvil

Dani quiere poder borrar desde el móvil una ventana o un espacio de trabajo, con confirmación,
y que desaparezca también del escritorio (Mac o Linux). Esto fija la forma en el cable.

## Capacidad
El host la anuncia en `capabilities` de `workspace.list` como **`box_close`**. Sin ella, el
móvil no ofrece cerrar: un botón que no hace nada es peor que no tenerlo.

## Métodos

### `workspace.close`
```json
{"workspace_id": "<id>"}
```

### `terminal.close`
```json
{"workspace_id": "<id>", "terminal_id": "<id>"}
```

Los dos responden **la lista completa**, con la misma forma que `workspace.list`, y además:
- `closed_workspace_id`, o
- `closed_terminal_id`.

El móvil la pinta tal cual, sin adivinar.

## Qué hace el host
**Exactamente lo mismo que cerrar esa ventana o ese espacio en el escritorio**, por el mismo
camino de código. No se inventa una semántica nueva.
- Si en el escritorio cerrar una ventana deja su sesión tmux viva (huérfana, recuperable), aquí
  también. Hoy es así en el Mac, por decisión de Dani del 14-oct.
- Si el escritorio pide confirmación, no se pide otra vez: la confirmación ya la hizo el móvil.
- Cerrar un espacio cierra todas sus ventanas, como en el escritorio.
- El último espacio de una ventana del escritorio también se puede cerrar: el escritorio
  queda como quedaría.
- Los demás clientes (otros móviles y el propio escritorio) lo ven por `workspace.updated`,
  como cualquier cambio.

## Errores
Errores RPC con código:
- `not_found`: no existe ese espacio o esa ventana. El móvil refresca la lista y dice que ya no
  estaba.
- `invalid_params`: falta un id o tiene una forma mala.
- `close_failed`: el host no pudo cerrarlo (por ejemplo, un diálogo modal del escritorio lo
  impide). El `message` es legible y en español.

## Registro (`log.v1`)
`ui.box_closed` (`info`), con `detail.kind` = `workspace|terminal` y `detail.source` = `mobile`.
Si falla, `ui.action_failed` con `detail.action = "close"` y `detail.cause`.

## Ejemplos
- `close-terminal-request.json` (los `params`)
- `close-terminal-response.json` (el `result`, recortado: la lista sigue la forma de `workspace.list`)
- `close-error-not-found.json` (el error RPC)
