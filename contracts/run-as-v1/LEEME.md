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
La ventana guarda en `agent.launch`:
- `run_as = {mode, method, user}`, sin contraseña;
- `environment.IS_SANDBOX = "1"` si la lleva.

Recuperar y relanzar respetan las dos cosas.

## Errores
Error RPC `run_as_failed`, con `cause`:
- `password_incorrect`;
- `not_allowed` (sudo no permitido);
- `user_not_found`;
- `timeout`;
- `wrong_user` (el usuario efectivo no es el pedido).

La ventana queda creada con su shell y SIN IA, y el móvil lo dice.

## Ejemplos
- `create-root-sandbox.json` (los `params` de `mobile.terminal.create`)
- `create-user-su.json`
