# `recent-prompts.v1`: cuándo se escribió el último prompt de cada ventana

Dani quiere en la pantalla de una máquina una pestaña **«Recientes»**. No lista espacios: lista
las **ventanas de todos los espacios**, ordenadas por la hora del **último prompt** que se
escribió en cada una, con una cajita que dice de qué espacio es. Cuenta el prompt escrito desde
cualquier sitio (escritorio, móvil o dictado), así que la fuente es la conversación de la IA, no
el teclado del móvil.

## Capacidad
`recent_prompts` en las `capabilities` de `workspace.list`.

## En el cable
Cada terminal de `workspace.list` (y de `workspace.updated`) lleva:

```json
{"id": "…", "title": "APP 2", "last_prompt_at": 1794150000}
```

- `last_prompt_at`: segundos desde época del último mensaje **del usuario** en la conversación
  actual de la IA de esa ventana; `null` si no hay IA, no hay conversación o no tiene ningún
  prompt.
- Solo cuentan los mensajes que escribió la persona:
  - Claude: entradas `type: "user"` con texto, sin `tool_result` ni comandos internos;
  - Codex: `user_message` del rollout.
- Nunca se manda el texto del prompt, solo la hora.

## Cómo lo saca el host
- De la conversación que ya conoce para esa ventana (`agent-tree-v1`: proveedor + `session_id`),
  leyendo **solo el final** del JSONL. Con caché por `mtime` y tamaño: solo se relee un
  fichero que cambió.
- Si la conversación está comprimida (`.jsonl.gz`, de transcript-retention), vale la hora que
  se guardó al comprimir, o `null`.
- Para ventanas SSH, la sonda remota (`agent_probe.py`) añade `last_prompt_at` a lo que ya
  devuelve, con la misma regla y sin traer el texto.

## En el móvil
- Pestaña «Recientes», la primera, solo si el equipo anuncia `recent_prompts`.
- Ventanas con `last_prompt_at` no nulo, de la más reciente a la más antigua, con:
  - el nombre de la ventana;
  - la cajita de su espacio;
  - «Hace 3 min»;
  - su actividad.
- Tocar abre la ventana; mantener pulsado, la hoja de siempre.
