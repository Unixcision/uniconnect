# transcript-retention-v1: cuánto se guardan las conversaciones de las IAs

Las conversaciones de Claude Code y Codex son ficheros `.jsonl` que crecen sin límite. En el Mac
de Dani llegaron a 15 GB. UniConnect para macOS y para Linux las mantiene con la misma regla,
decidida por Dani el 5-11-2026:

- **Cada hora** se revisan.
- **Más de 30 días sin tocar** → se comprime en el sitio: `<x>.jsonl` pasa a `<x>.jsonl.gz`
  con la misma fecha. `gzip -dc` devuelve exactamente el original.
- **Más de 365 días sin tocar** → se borra, comprimida o no.
- **Nunca se toca una conversación en uso**: la de cualquier ventana de UniConnect y la de
  cualquier IA viva. Si se comprimiera, la IA seguiría escribiendo en un `.jsonl` nuevo y la
  conversación quedaría partida en dos.

UniConnect no copia conversaciones a ningún otro sitio. Claude Code borra por su cuenta las
conversaciones con 30 días sin tocar (`cleanupPeriodDays`), así que en la máquina se sube a 400
días para que mande esta regla.

## Qué ficheros

Las raíces son `~/.claude/projects` (Claude) y `~/.codex/sessions` (Codex), en el usuario con el
que corren las IAs: en el MINIPC es root. Solo cuentan ficheros normales terminados en `.jsonl`
o `.jsonl.gz`. Ni enlaces ni carpetas: se ignora todo lo demás.

La edad es la de la última modificación (`mtime`), en días, y el límite es estricto: con 30 días
exactos todavía no se comprime.

## Conversación en uso

Una ruta está en uso si **cualquier UUID que aparezca en ella** (en minúsculas) está en el
conjunto protegido. Así se protegen a la vez:

- `claude/<proyecto>/<uuid>.jsonl`: la conversación.
- `claude/<proyecto>/<uuid>/subagents/agent-*.jsonl`: sus subagentes.
- `codex/2026/11/04/rollout-2026-11-04T18-43-14-<uuid>.jsonl`: Codex.

El conjunto protegido sale de:

1. **Todo UUID del estado de UniConnect.** En el Mac, la instantánea de sesión. En Linux, el
   almacén de estado. Sobran UUIDs que no son conversaciones (ventanas, cajas), pero no hacen
   daño: nunca coinciden con el nombre de una conversación.
2. **Cada IA viva**: `~/.claude/sessions/<pid>.json` con `sessionId`, si el proceso `<pid>`
   sigue vivo.

## Comprimir sobre un `.gz` que ya existe

Pasa si una conversación archivada se retomó: la IA escribió un `.jsonl` nuevo al lado del
`.gz`. Lo nuevo se **añade al final del `.gz` como otro miembro gzip**, y al descomprimir sale
lo viejo seguido de lo nuevo.

## Cómo se aplica sin perder nada

1. Se comprime a `<x>.jsonl.gz.tmp`. Si ya había un `.gz`, el temporal empieza siendo una copia
   suya.
2. Se comprueba el temporal (`gzip -t` o equivalente).
3. Si el original cambió de tamaño o de fecha mientras tanto, se descarta el temporal y se deja
   para la siguiente hora.
4. El temporal toma la fecha del original y se renombra a `<x>.jsonl.gz`. Solo entonces se borra
   el original.
5. Si el original cambió justo después del renombrado, el `.gz` vuelve a ser el de antes (o se
   borra si era nuevo) y el original se queda para la siguiente hora.
6. Las carpetas que se quedan vacías dentro de la raíz se quitan. La raíz, nunca.

En cada pasada se borra primero y se comprime después: lo nuevo no se añade a un `.gz` que se va
a borrar. Si una pasada se cortó entre renombrar y borrar el original, el `.gz` tiene la misma
fecha que el original: solo queda borrar el original, sin volver a añadirlo.

## Casos

`cases.json` tiene la política y los casos que las dos implementaciones deben cumplir con su
función de plan pura. Las rutas empiezan por la raíz lógica (`claude/` o `codex/`).
