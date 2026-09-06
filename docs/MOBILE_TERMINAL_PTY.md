# Terminal real móvil: contrato PTY v1

Contrato común para los adaptadores Mac/Linux y el cliente Android, junto al
modo espejo existente. `mobile.host.status` anuncia `terminal.pty.v1` cuando el
host implementa este modo; anunciarlo no garantiza que una ventana tenga tmux.
La implementación Linux usa sus adaptadores nativos de PTY/OpenSSH; no implica
que ese código Python sea una implementación ejecutable compartida con Mac.

## Conexión e identidad

Se usa la conexión enmarcada y aprobada de Tailscale existente. Android no recibe
credenciales. Local conecta al tmux guardado; SSH abre otro cliente hacia el mismo
usuario/host/socket/sesión/pane con la revisión de credenciales del host.
Linux crea una sesión auxiliar de presentación y enlaza la ventana original,
con sus mismos panes y procesos. Su placeholder ejecuta directamente `/bin/sleep`
con argumento `60` (sin shell/default-command) y se reemplaza al enlazar: no
crea ni relanza una IA ni escribe en la VTE del escritorio. Esta referencia
permite seleccionar ventanas sin cambiar las del PC. Sólo la auxiliar lleva
`destroy-unattached`; tmux la elimina al cerrar su cliente. No se usa una sesión
agrupada porque tmux puede ejecutar el shell por defecto antes de formar el grupo.
Una ventana sin destino durable devuelve `not_durable`; un arranque fallido,
`attach_failed`. No existe alternativa implícita a otro destino o shell.

Antes de adjuntar, suscribir `terminal.pty` mediante `mobile.events.subscribe` en
la misma conexión y comprobar que el host acepta ese topic. El identificador de
propiedad es el de la conexión autenticada del servidor, no `client_id` enviado.

| RPC | Petición | Respuesta |
|---|---|---|
| `mobile.terminal.attach` | `workspace_id`, `surface_id`, `client_id`, `columns`, `rows` | Los dos IDs de destino, `attach_id`, `columns`, `rows` |
| `mobile.terminal.pty_input` | `attach_id`, `data` base64 | `attach_id`, `queued:true` |
| `mobile.terminal.pty_resize` | `attach_id`, `columns`, `rows` | `attach_id`, `columns`, `rows` |
| `mobile.terminal.detach` | `attach_id` | `ok:true` |

Un máximo de cuatro adjuntos por conexión, uno por terminal. Repetir attach para
el mismo destino devuelve el adjunto existente; resize es explícito. Dimensiones:
enteros entre 1 y 1000. Entrada: entre 1 y 65.536 bytes **decodificados**, base64
estricto. Una cola de entrada llena responde `busy`, sin fingir aceptación.

## Flujo y cierre

Eventos privados, nunca difundidos a otras conexiones aunque tengan la misma IP:
`{kind:"event", topic:"terminal.pty", payload:{attach_id,surface_id,seq,data}}`.
`data` contiene hasta 65.536 bytes crudos codificados en base64. `seq` empieza en
cero y aumenta por adjunto. La respuesta de attach se encola antes del primer
evento. No se agrupan ni descartan fragmentos. La salida final añade `exit:true`
en vez de datos. No es un render_grid ni requiere snapshots de 5000 líneas.

La cola de salida Linux está limitada a 2 MiB/128 mensajes. Un consumidor que no
puede seguir el flujo pierde la conexión explícitamente; no continúa con bytes
omitidos. Reconectar crea otro adjunto y reinicializa el emulador: no hay replay
de bytes PTY. Desconexión, revocación, bloqueo o cambio de identidad cancelan los
clientes propios y su referencia auxiliar, nunca la sesión original, sus panes o sus IA.

## Tamaño y límites nativos

El cliente tmux usa `ignore-size,active-pane`, no `window-size largest`, y no
modifica mouse, opciones compartidas ni entorno de la sesión original (`-E`).
Con un cliente de escritorio conectado, el tamaño del móvil afecta a su PTY,
no al cálculo del tamaño del escritorio. Si no queda ningún cliente de escritorio,
tmux puede usar el tamaño del móvil: no se bloquean esas sesiones guardadas.
El programa dentro del pane sigue teniendo **una geometría compartida**: no se
promete un reflujo independiente del mismo programa para cada cliente.

No se cambia la ventana seleccionada del escritorio para alcanzar un pane
oculto: se selecciona sólo en la auxiliar. La sesión auxiliar y `active-pane`
aíslan las selecciones del PC. Después de conectar es un cliente tmux real:
si se elimina un pane por fuera de UniConnect, tmux puede seleccionar otro;
no se garantiza fijación perpetua a un pane eliminado. La rueda depende de los modos de ratón anunciados por tmux;
se conserva su configuración. El modo copia pertenece a tmux, no al historial
local del emulador ni a una nueva instancia del programa.
