# Recuperación remota de sesiones

`recovery.py` mantiene vivas en un VPS las ventanas tmux de su manifiesto, cada una con la IA que
tenía y en su misma conversación, y las devuelve todas tras un reinicio del servidor o una caída de
tmux. El modelo común está en `docs/ARBOL-IA-v1.md`; los ejemplos normativos, en
`contracts/agent-tree-v1/`.

## Qué hace

- **Recupera siempre sin preguntas** (decisión de Dani del 24-09-2026):
  - Claude: `claude --resume <id> --dangerously-skip-permissions`. Como root, además con
    `IS_SANDBOX=1`: sin esa variable Claude rechaza su modo sin preguntas.
  - Codex: `codex --yolo resume <id> -C <cwd> [-m <modelo>] [-c model_reasoning_effort=…]`.
  - Antigravity: `agy --dangerously-skip-permissions --conversation <id>`.
  - Grok: `grok -r <id>`. No hay bandera sin preguntas verificada y no se inventa.
  - Un agente que no conoce da error en esa entrada; no se lanza otro en su lugar.
- **Aprende** (`snapshot`) las sesiones que existen ahora con el criterio común de detección: el
  subárbol de procesos del shell de cada panel, exactamente una IA raíz, la ficha de Claude
  (`~/.claude/sessions/<pid>.json`, y `/root/.claude/sessions` si la IA corre como root), el rollout
  abierto por Codex y, como último recurso, la línea de órdenes. Mira **todos** los paneles de cada
  sesión y se queda con el único que tenga IA; con IA en dos, no toca nada. Una IA sin
  conversación todavía (un `claude login`, un Codex recién abierto) tampoco cambia lo guardado.
- Cada entrada aprendida guarda de dónde salió el dato (`source`: `ficha`, `rollout` o `argv`) y si
  la IA corría como root (`asRoot`).
- **No reabre una conversación abierta en otra parte**: en Claude, una ficha viva con ese
  `sessionId`; en Codex, su rollout abierto o el cerrojo del kernel de
  `~/.codex/thread-writer-locks/<id>.lock`; en agy, su cerrojo de presencia. La ventana espera a que
  la otra salga. No se envían señales ni teclas a nadie.
- **Olvida** lo que se cerró a propósito: si falta una sesión con el mismo arranque de la máquina y
  el mismo servidor tmux vivo, fue un cierre a mano. Si faltan todas las de un servidor, o la
  máquina arrancó de nuevo, fue una caída y se recrea todo.

Lo que no hace nunca: enviar teclas, cambiar opciones de una sesión que ya existía, matar procesos o
usar sudo. `set-clipboard off` (el arreglo del fallo de tmux viejo con OSC 52) solo se aplica al
**crear** una sesión, no en cada vuelta.

Sigue haciendo una escritura fuera de su carpeta, que queda como riesgo conocido: antes de reabrir
Claude marca la carpeta como de confianza en `~/.claude.json` (`trust_folder_for_claude`), porque
durante una recuperación no hay nadie para contestar «¿confías en esta carpeta?».

## Manifiesto

Se guarda fuera del repositorio, con permisos 600.

```json
{
  "schema": "uniconnect-recovery/v1",
  "tmuxSocket": "uniconnect",
  "tmuxSockets": ["uniconnect", "default"],
  "windows": [
    {
      "workspace": "Proyecto",
      "name": "Desarrollo",
      "tmux": "uc-desarrollo-00000000",
      "tmuxSocket": "uniconnect",
      "agent": "codex",
      "sessionId": "00000000-0000-0000-0000-000000000000",
      "cwd": "/ruta/original",
      "repo": "/ruta/repositorio",
      "model": "gpt-6-astra",
      "reasoningEffort": "max",
      "source": "rollout",
      "asRoot": false
    }
  ]
}
```

- `tmuxSocket`: el servidor tmux por defecto de las entradas. `default` es el servidor por defecto
  de tmux (el de `tmux` a secas).
- `tmuxSockets` (opcional): todos los servidores que se vigilan. Sin ella, solo `tmuxSocket`.
- En cada entrada, `tmuxSocket` (opcional) dice en qué servidor vive esa ventana.
- `agent`: `claude`, `codex`, `agy`, `grok` o `command` (una orden normal con `command`).
- `model` y `reasoningEffort` son opcionales: sin ellos se conserva la configuración del cliente.
- `repo` puede ser `null` si el inventario original no asigna un producto.
- `source` y `asRoot` los escribe `snapshot`.
- `adopted: true` lo pone el supervisor en una sesión que **no creó él** (la aprendió viva). Se
  vigila, pero nunca se le cambian opciones ni se reabre su panel; si se cae, se recrea y deja de
  ser adoptada.
- `tmuxOwner` lo pone el supervisor al crear una sesión: el dueño que escribió en
  `@uniconnect_session_id`. Una sesión con otro dueño se salta y se avisa, sin excepción.
- `seen` lo mantiene el supervisor: el arranque de la máquina y las sesiones vistas.

No se convierten conversaciones entre proveedores.

El manifiesto se **relee en cada vuelta**, y lo aprendido se fusiona sobre lo que hay en el disco
en ese momento: un `forget` o una edición a mano hechos mientras el supervisor trabajaba no se
pierden.

## Acciones

```sh
M="$HOME/.uniconnect/recovery/manifest.json"
python3 "$HOME/.uniconnect/recovery/recovery.py" --manifest "$M" validate   # comprueba; no arranca nada
python3 "$HOME/.uniconnect/recovery/recovery.py" --manifest "$M" snapshot   # aprende lo que corre ahora
python3 "$HOME/.uniconnect/recovery/recovery.py" --manifest "$M" ensure     # crea lo que falte, una vez
python3 "$HOME/.uniconnect/recovery/recovery.py" --manifest "$M" supervise  # ensure + snapshot cada 15 s
python3 "$HOME/.uniconnect/recovery/recovery.py" --manifest "$M" status     # estado, sin tocar nada
python3 "$HOME/.uniconnect/recovery/recovery.py" --manifest "$M" forget NOMBRE_TMUX [--socket S]
```

`status` devuelve, por ventana: `socket`, `agent`, `sessionId`, `source`, `adopted`, si está viva,
si su panel murió, si la conversación está abierta en otra parte y `resumeCommand`, la orden exacta
con la que se reanudaría (`cd -- '<cwd>' && [IS_SANDBOX=1 ]claude --resume … --dangerously-skip-permissions`).

Mensajes del supervisor: «Aprendida», «Actualizada», «Olvidada», «Creada», «Reabierta» y, si algo
falla, «La recuperación necesita atención». Una entrada rota se apunta una vez y no para a las
demás.

## Instalación

En el servidor SSH, con Claude, Codex o agy disponibles en el PATH de un shell de login, y tmux,
Python 3 y systemd de usuario instalados. La unidad va en el repo como
`uniconnect-recovery.service.in`: con la extensión `.service` a secas, macOS la toma por una app de
Servicios y sale rota en el buscador de apps del Mac que tiene el repo; al instalarla recupera su
nombre de systemd:

```sh
install -d -m 700 "$HOME/.uniconnect/recovery" "$HOME/.config/systemd/user"
install -m 700 recovery.py "$HOME/.uniconnect/recovery/recovery.py"
install -m 600 manifest.json "$HOME/.uniconnect/recovery/manifest.json"
install -m 600 uniconnect-recovery.service.in "$HOME/.config/systemd/user/uniconnect-recovery.service"
python3 "$HOME/.uniconnect/recovery/recovery.py" --manifest "$HOME/.uniconnect/recovery/manifest.json" validate
systemctl --user daemon-reload
systemctl --user enable --now uniconnect-recovery.service
```

Para sobrevivir al cierre del login y arrancar tras reiniciar el servidor, el usuario necesita
`Linger=yes` (`loginctl show-user "$USER" -p Linger`). Si todavía no está habilitado, el
administrador debe habilitarlo para ese usuario.

Al salir normalmente de un cliente, la ventana ofrece Intro para volver a abrir el mismo historial;
un error del cliente se reintenta tras 30 segundos.

```sh
tmux -L uniconnect attach-session -t '=NOMBRE_TMUX_DEL_MANIFIESTO'
systemctl --user stop uniconnect-recovery.service
```

Parar el servicio detiene solo el supervisor y conserva las conversaciones tmux. Las pruebas de
reinicio del host requieren una ventana operativa propia; no se reinicia un servidor de trabajo para
comprobar esta instalación. Esta versión no se ha desplegado en ningún VPS: los manifiestos y
servicios vivos solo se han leído.

## Pruebas

```sh
python3 -m pytest -q -p no:cacheprovider linux/tests/test_recovery.py
python3 -m pytest -q -p no:cacheprovider linux/tests/test_recovery_v2.py
```

`test_recovery_v2.py` pasa por la detección y la guarda reales todos los casos de
`contracts/agent-tree-v1/deteccion-casos.json`, y por las órdenes todos los de
`reanudar-comandos.json`. La copia de la política sin preguntas se compara con
`agent-resume-v1.json` en cuanto el catálogo traiga `noPrompt`.
