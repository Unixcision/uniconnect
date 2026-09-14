#!/bin/bash
#
# Cierra y reabre los Claude que viven en las sesiones tmux de UniConnect, dejando
# cada uno como estaba: misma ventana, misma conversación, mismas banderas.
#
# Uso:
#   scripts/relanzar-claudes.sh --listar                 qué hay, sin tocar nada
#   scripts/relanzar-claudes.sh --todos                  todos menos el que lo invoca
#   scripts/relanzar-claudes.sh %8 %13                   solo esos paneles
#   scripts/relanzar-claudes.sh --socket otro --todos    otro servidor tmux
#
# POR QUÉ EXISTE
# Reiniciar un Claude a mano es media hora de teclas y tres formas distintas de
# romper una sesión. Esto lo hace igual siempre y, sobre todo, NO manda teclas a
# ciegas: antes de cada paso mira qué hay en la pantalla.
#
# LO QUE HAY QUE SABER, aprendido a base de romperlo:
#   - `Ctrl+C` no cierra Claude y `Ctrl+D` tampoco si queda algo escrito. Cierra `/exit`.
#   - Al salir, Claude imprime `Resume this session with: claude --resume <id>`. Ese id
#     es la fuente de verdad: vale también para las sesiones que se lanzaron sin
#     `--resume` y que, por su línea de comandos, no se sabría cuál continuar.
#   - Un Claude con trabajo de fondo pregunta antes de irse. Se elige «salir y parar las
#     tareas»: dejarlas en segundo plano deja un vigilante huérfano mientras la sesión
#     resucitada arranca el suyo, y acabas con dos mirando lo mismo.
#   - Un panel puede no estar en el prompt (vista de tareas, panel de uso). Hay que
#     sacarlo con Escape antes de nada, o las teclas acaban dentro de un cuadro de texto.
#   - Al arrancar, Claude puede pedir «¿confías en esta carpeta?» con «No, exit»
#     preseleccionado. Un Enter a ciegas ahí mata la sesión recién abierta.
#
set -uo pipefail

SOCKET="uniconnect-local"
TMUX_BIN="${TMUX_BIN:-$(command -v tmux || echo /opt/homebrew/bin/tmux)}"
PANELES=()
TODOS=0
LISTAR=0

while [ $# -gt 0 ]; do
  case "$1" in
    --socket) SOCKET="$2"; shift 2 ;;
    --todos) TODOS=1; shift ;;
    --listar) LISTAR=1; shift ;;
    -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    %*) PANELES+=("$1"); shift ;;
    *) echo "opción desconocida: $1" >&2; exit 2 ;;
  esac
done

tm() { "$TMUX_BIN" -L "$SOCKET" "$@"; }
pantalla() { tm capture-pane -p -t "$1" 2>/dev/null; }
proceso() { tm display -p -t "$1" '#{pane_current_command}' 2>/dev/null; }

# El panel desde el que se lanza esto: reiniciarlo mataría a quien está ejecutando
# el script a media faena.
propio_panel() {
  local raiz="${CMUX_CLAUDE_WRAPPER_SHIM_ROOT:-}"
  [ -z "$raiz" ] && { echo ""; return; }
  local uuid; uuid=$(basename "$raiz" | tr 'A-Z' 'a-z' | tr -d '-')
  tm list-panes -a -F '#{session_name}|#{pane_id}' 2>/dev/null |
    awk -F'|' -v u="uc-$uuid" '$1==u {print $2; exit}'
}

claudes() {
  tm list-panes -a -F '#{pane_id}|#{pane_pid}|#{pane_current_command}|#{pane_current_path}' 2>/dev/null |
    awk -F'|' '$3=="claude.exe" {print $1"|"$2"|"$4}'
}

if [ "$LISTAR" = 1 ]; then
  mio=$(propio_panel)
  claudes | while IFS='|' read -r pane ppid path; do
    marca=""; [ "$pane" = "$mio" ] && marca="  <- este script corre aquí"
    printf '%-6s %s%s\n' "$pane" "$path" "$marca"
  done
  exit 0
fi

if [ "$TODOS" = 1 ]; then
  while IFS='|' read -r pane _ _; do PANELES+=("$pane"); done < <(claudes)
fi
[ ${#PANELES[@]} -eq 0 ] && { echo "nada que hacer: usa --todos, --listar o pasa paneles" >&2; exit 2; }

MIO=$(propio_panel)
fallos=0

for pane in "${PANELES[@]}"; do
  if [ "$pane" = "$MIO" ]; then echo "$pane  saltado: es el panel que ejecuta esto"; continue; fi
  ruta=$(tm display -p -t "$pane" '#{pane_current_path}' 2>/dev/null)
  if [ "$(proceso "$pane")" != "claude.exe" ]; then echo "$pane  saltado: aquí no corre Claude"; continue; fi

  # Un panel en otra vista se lleva las teclas a su propio cuadro de texto.
  for _ in 1 2; do tm send-keys -t "$pane" Escape; sleep 1; done

  tm send-keys -t "$pane" "/exit"; sleep 1; tm send-keys -t "$pane" Enter
  salio=0
  for _ in $(seq 1 30); do
    sleep 1
    [ "$(proceso "$pane")" = "zsh" ] && { salio=1; break; }
    if pantalla "$pane" | grep -q "Background work is running"; then
      tm send-keys -t "$pane" Enter   # «Exit and stop tasks», la primera opción
      sleep 2
    fi
  done
  if [ "$salio" = 0 ]; then echo "$pane  NO SALIÓ, lo dejo como estaba  ($ruta)"; fallos=$((fallos+1)); continue; fi

  id=$(pantalla "$pane" | grep -A1 "Resume this session with" |
       grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
  if [ -n "$id" ]; then orden="claude --resume $id --dangerously-skip-permissions"
  else orden="claude --continue --dangerously-skip-permissions"; fi

  tm send-keys -t "$pane" "$orden"; sleep 1; tm send-keys -t "$pane" Enter
  volvio=0
  for _ in $(seq 1 35); do
    sleep 1
    # «¿Confías en esta carpeta?» llega con «No, exit» preseleccionado.
    if pantalla "$pane" | grep -q "Yes, I trust this folder"; then
      tm send-keys -t "$pane" Down; sleep 1; tm send-keys -t "$pane" Enter; sleep 3
    fi
    [ "$(proceso "$pane")" = "claude.exe" ] && { volvio=1; break; }
  done
  sleep 3
  if [ "$volvio" = 1 ] && pantalla "$pane" | grep -q "bypass permissions on"; then
    printf '%-6s OK   sesión=%s  %s\n' "$pane" "${id:0:8}" "$ruta"
  else
    printf '%-6s REVISAR (proceso=%s)  %s\n' "$pane" "$(proceso "$pane")" "$ruta"
    fallos=$((fallos+1))
  fi
done

echo "---"
[ "$fallos" -eq 0 ] && echo "todo en orden" || echo "$fallos para revisar a mano"
exit 0
