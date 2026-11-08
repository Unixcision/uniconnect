# `run-as.v1`: al crear, elegir con qué usuario corre la IA y si va con IS_SANDBOX

Dani trabaja siempre contra máquinas Linux, locales o VPS. Algunas ventanas tienen que correr
como root, por ejemplo la caja MINIPC dentro del Mac: entra como `dgomezm`, sube a root y lanza
Claude con `IS_SANDBOX=1`. Otras, con un usuario concreto. Al crear la ventana, desde el móvil o
desde el escritorio, hay que poder elegirlo, sin hacerlo a mano después.

## Capacidad
`run_as` en las `capabilities` de `workspace.list`. Sin ella, el móvil no ofrece la opción.

## Parámetros nuevos
Opcionales y aditivos, en `mobile.terminal.create` y en `workspace.create` cuando crea la
primera ventana:

```json
{
  "run_as": {"mode": "root", "method": "sudo", "user": null, "password": "…"},
  "is_sandbox": true
}
```

- `run_as.mode`:
  - `current` (por defecto, como hoy): el usuario con el que se conecta la caja.
  - `root`: root.
  - `user`: el usuario de `run_as.user`.
- `run_as.method`:
  - `sudo` (por defecto): `sudo -S -i` para root o `sudo -S -iu <user>` para un usuario, con la
    contraseña del usuario CONECTADO.
  - `su`: `su -` / `su - <user>`, con la contraseña del usuario DESTINO.
- `run_as.password`: contraseña para subir de usuario. Ausente si la máquina no la pide
  (`sudo` sin contraseña).
- `is_sandbox`: si es `true`, la IA arranca con `IS_SANDBOX=1` en su entorno, que es lo que
  Claude necesita para usar `--dangerously-skip-permissions` como root. Por defecto `false`.
  El móvil lo marca solo al elegir root, y la persona puede desmarcarlo.

La IA arranca siempre sin preguntas, con la política `noPrompt` de cada proveedor
(`agent-tree-v1/reanudar-comandos.json`): Claude con `--dangerously-skip-permissions`, Codex con
`--yolo`, etc.

## Qué hace el host
1. Crea la sesión tmux como hoy.
2. Dentro, sube de usuario con `method` y la contraseña. La contraseña se pasa por la entrada del
   PTY o por un `askpass` efímero, **nunca** por `argv` ni por el entorno.
3. Ya con ese usuario: `cd` a la carpeta, `export IS_SANDBOX=1` si toca, y lanza la IA con su
   política sin preguntas.
4. Comprueba que el usuario efectivo es el pedido (`id -un`) antes de lanzar la IA. Si no lo es,
   la IA NO se lanza.

## Contraseñas
- El móvil no la guarda nunca: ni en disco, ni en el historial, ni en el diario.
- El host la guarda en su **bóveda**, la de `ssh_create.v1` (Llavero en el Mac, `vault.py` en
  Linux), ligada a esa ventana. Así relanzar o recuperar tras un apagado pueden volver a subir
  de usuario sin preguntar. Al cerrar la ventana (`box-close.v1`) se borra de la bóveda.
- Nunca aparece en `log.v1`, ni en `agent-tree.json`, ni en `workspace.list`, ni en Detalles, ni
  en ningún error.

## En el árbol (`agent-tree-v1`)
`run_as` va a nivel de **ventana** (vale para cualquier tipo, también terminales):
`window.run_as = {mode, method, user}`, sin contraseña. Si es `current`, `null` o ausente.
`IS_SANDBOX` sigue en `agent.launch.environment`, que solo existe con IA.
Recuperar y relanzar respetan las dos cosas.

## Errores
Error RPC `run_as_failed`, con `cause` y con `created_terminal_id` (la ventana existe):
`{"code": "run_as_failed", "message": "…", "cause": "password_incorrect", "created_terminal_id": "…"}`.
Causas (de los mensajes de sudo/su en `LC_ALL=C`, ver abajo):
- `password_incorrect`;
- `not_allowed` (sudo no permitido);
- `user_not_found`;
- `timeout`;
- `wrong_user` (el usuario efectivo no es el pedido);
- `failed`: cualquier otra cosa. El mensaje no copia la salida de sudo/su.

La ventana queda creada con su shell y SIN IA, y el móvil lo dice.

## Decisiones del 08-11 (`coordNov`, Mac y Linux)
1. **`runAs` es lo pedido; `asRoot`, lo observado.** `asRoot` (o `as_root` en la sonda) sigue
   siendo lo que ve la sonda: la IA corre con uid 0. Linux guarda en la ventana
   `runAs = {mode, method, user, credentialId}`; el Mac, lo equivalente.
2. **Claude como root lleva SIEMPRE `IS_SANDBOX=1`**: sin él no arranca sin preguntas. La casilla
   cuenta para el resto (no-root y otras IAs). El móvil y el escritorio la enseñan marcada y
   bloqueada en ese caso, con una nota.
3. **Cómo se sube: el envoltorio compartido `subir.sh`** (este directorio). Linux y el Mac
   ejecutan el mismo texto como orden del panel:
   `sh -c "$(subir.sh)" uc-subir <sudo|su> <usuario> <id-ventana> <orden>`. `<orden>` es lo que
   el panel ejecutaría sin subir. El envoltorio:
   - deja su diario en `$HOME/.local/state/uniconnect/runas/<id>.log` (carpeta 0700). Lleva los
     mensajes de sudo/su en `LC_ALL=C` y las marcas `UC_RUNAS_OK <usuario>`,
     `UC_RUNAS_WRONG <usuario>` y `UC_RUNAS_END <estado>`. Sin secretos;
   - comprueba `id -un` ya como el usuario pedido. Si no coincide, la orden no se ejecuta;
   - con `su` usa `--session-command` si existe. `su -c` abre una sesión sin terminal de control
     y la IA se queda sin TTY;
   - devuelve a la ventana su `LC_ALL` de antes;
   - al terminar, o si falla, sigue con el shell del usuario de conexión, sin IA.
4. **La contraseña.** Nunca va por argv, ni por el entorno, ni por `tmux send-keys`, que la
   dejaría en el argv del cliente tmux.
   - `sudo`: el host la escribe en `<dir>/<id>.secret` (0600) por la entrada estándar de ssh, o
     de bash en local, justo antes de crear la sesión. El envoltorio usa `sudo -A` con un askpass
     que la lee y la borra. Si sudo no la pide, se borra a los 30 s. Si la sesión ya existía, o
     no se pudo crear, el host la borra en el mismo paso.
   - `su`: el host espera, como mucho 20 s, a que el diario acabe en `Password: ` y a que `su`
     sea hijo del proceso del panel (`pgrep -P <pane_pid> -x su`; `pane_current_command` dice
     `sh`). Entonces la pega con `tmux load-buffer -b uc-rs-<id> -`, desde la entrada estándar,
     y `paste-buffer -d`, más `send-keys Enter`. Si el diario llega a `UC_RUNAS_` antes, no
     pega nada. Nunca se pega en un shell ni en una IA.
5. **El resultado.** Tras crear, el host espera como mucho 30 s a `UC_RUNAS_OK` o
   `UC_RUNAS_END` en el diario. Si no llega ninguna, la causa es `timeout`. Las causas salen del
   diario:

   | En el diario | `cause` |
   |---|---|
   | `UC_RUNAS_OK` | — (bien) |
   | `UC_RUNAS_WRONG` | `wrong_user` |
   | `incorrect password`, `Sorry, try again`, `no password was provided`, `Authentication failure` | `password_incorrect` |
   | `is not in the sudoers file`, `is not allowed to`, `may not run sudo` | `not_allowed` |
   | `unknown user`, `does not exist` | `user_not_found` |
   | `UC_RUNAS_END` sin nada de lo anterior | `failed` |

6. **Claude con `--session-id <uuid>` elegido al crear**, cuando sube de usuario. Así el id se
   sabe desde el primer segundo y la sonda lo ve en el argv. Como dgomezm no se pueden leer la
   ficha de `/root/.claude/sessions` ni `/proc/<pid>/environ|fd` de un proceso de root.
   `--session-id` es selector: no entra en `agent.launch.arguments`. Codex como root desde un
   usuario no root no tiene id hasta que se pueda leer su rollout, y Detalles lo dice.
7. **Relanzar una ventana que sube de usuario** no va por el trabajador remoto: este corre como
   el usuario de conexión, matar la IA de root daría EPERM, y respawn-pane perdería la subida.
   La escalera es:
   - `/exit` y espera acotada;
   - matar la sesión tmux;
   - recrearla por el camino de crear: `subir.sh`, la clave de la bóveda y la conversación con
     `--resume`.
   Recuperar tras un apagado va por ese mismo camino.
8. **Bóveda.** Una entrada propia por ventana: sin deduplicar, y la clave tal cual, sin recortar
   espacios.
   - Al cerrar la ventana (`box-close.v1`) se borran la clave y su referencia en «Reabrir».
     Reabrirla la abre con el usuario de conexión, sin subir, y lo avisa.
   - Las copias de seguridad cifradas que ya existen (Linux: cada 6 h, con su bóveda) la
     conservan hasta que rotan. «Borrar al cerrar» borra de la bóveda viva, no de esas copias.
9. **Local.** En el MINIPC la app ya corre como root: `root` no hace nada, y `user` es
   `su - <user>` sin contraseña. `current` nunca usa el envoltorio.

## Ejemplos
- `create-root-sandbox.json` (los `params` de `mobile.terminal.create`)
- `create-user-su.json`
- `subir.sh`: el envoltorio compartido (probado el 08-11 contra un contenedor con sudo 1.9.15 y
  su de util-linux: sudo y su a root y a otro usuario, clave mala, sin sudoers, usuario que no
  existe, y una clave con espacios delante y detrás).
