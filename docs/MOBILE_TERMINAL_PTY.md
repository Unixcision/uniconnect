# Terminal real móvil: contrato PTY v1

Contrato común para los adaptadores Mac/Linux y el cliente Android, junto al
modo espejo existente. `mobile.host.status` anuncia `terminal.pty.v1` cuando el
host implementa este modo; anunciarlo no garantiza que una ventana tenga tmux.
La implementación Linux usa sus adaptadores nativos de PTY/OpenSSH; no implica
que ese código Python sea una implementación ejecutable compartida con Mac.

macOS implementa el mismo protocolo con `MobilePTYProcess` (PTY Darwin),
`MobileTmuxTargetResolver` (identidades guardadas) y un controlador por conexión.
El comando local pasa por un descriptor privado; no se registra ni se escribe en
disco. Las credenciales SSH permanecen en el host. Ambas plataformas usan una
sesión auxiliar de presentación enlazada a los procesos originales, no otra IA.

En Mac, el ACK de attach acredita que se lanzó el cliente, no que una conexión
SSH haya terminado de autenticarse. Un fallo posterior del comando termina el
flujo con `exit:true`, `exit_code` y `error`; no se cambia de destino. El cliente
debe observar ese cierre. La cola PTY Mac conserva hasta 64 fragmentos de 64 KiB;
si se desborda se cierra explícitamente, sin continuar con bytes omitidos.

## Cerrar la app no es reiniciar el equipo

Cerrar UniConnect sólo desconecta clientes: el servidor tmux y las IA existentes
siguen vivos. Reiniciar el equipo sí destruye esos procesos. En macOS, la
restauración reconstruye los modelos con sus UUID, socket y nombre tmux guardados;
las pestañas locales ocultas también se encolan para arrancar sin seleccionarlas.
`new-session -A` reanuda la conversación guardada únicamente al crear una sesión
ausente, respetando la preferencia de autorreanudar y la disponibilidad del cwd.

El estado «IA activa» de un pane local se reconcilia antes del guardado asíncrono
con su proceso real, propietario y UUID conocido; un hook con PID antiguo o el
prompt del shell exterior no acreditan que esa IA terminó. La recuperación
adicional implementada reconoce Claude con UUID explícito en argv. Si falta
evidencia, conserva el registro: no inventa una sesión ni relanza otra IA.
Los tmux antiguos cuyo shell raíz carece por completo de metadatos de integración
pueden reconciliar una IA conocida mediante su descendiente Claude verificado
(propietario, árbol de procesos, generación, UUID y carpeta). Esta compatibilidad
sólo repara el estado guardado: no amplía la autorización de comandos del socket.
Metadatos parciales o contradictorios no se aceptan como una raíz antigua.
No se recuperan los PID ni la memoria del proceso anterior. Las pruebas de
recreación aislada no equivalen a haber reiniciado el Mac de producción.

El arranque en frío Linux requiere su propia validación y no queda acreditado
por el adaptador Mac. Tampoco el protocolo PTY corrige por sí solo la selección,
los menús o los enlaces del escritorio; su operativa debe seguir siendo la de
UniConnect, no exigir gestos adicionales de tmux.

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

Los IDs de pane nativos (`%N`) se validan exactamente. Si Linux guarda un ID de
layout (`main`, `pane-…`), sólo se resuelve dentro de la sesión guardada cuando
contiene una única ventana y un único pane; un destino ambiguo se rechaza sin
crear un adjunto. El ID de layout y la conversación persistida no se modifican.

Antes de adjuntar, suscribir `terminal.pty` mediante `mobile.events.subscribe` en
la misma conexión y comprobar que el host acepta ese topic. El identificador de
propiedad es el de la conexión autenticada del servidor, no `client_id` enviado.

| RPC | Petición | Respuesta |
|---|---|---|
| `mobile.terminal.attach` | `workspace_id`, `surface_id`, `client_id`, `columns`, `rows` | Los dos IDs de destino, `attach_id`, `columns`, `rows`; geometría opcional descrita abajo |
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
Mac y Linux activan `mouse on` únicamente en la auxiliar móvil que crea cada
attach, para que reciba los eventos de rueda SGR del cliente. No cambian la
opción global ni la de las sesiones existentes. La aplicación dentro del pane
y los bindings de tmux siguen determinando cómo se trata esa rueda.
Con un cliente de escritorio conectado, el tamaño del móvil afecta a su PTY,
no al cálculo del tamaño del escritorio. Si no queda ningún cliente de escritorio,
tmux puede usar el tamaño del móvil: no se bloquean esas sesiones guardadas.
El programa dentro del pane sigue teniendo **una geometría compartida**: no se
promete un reflujo independiente del mismo programa para cada cliente.

### Geometría opcional de presentación

`columns/rows` conservan el tamaño del PTY solicitado. La respuesta de attach y
los eventos `terminal.pty` pueden añadir estos cuatro campos cuando el adaptador
dispone de una lectura nativa, sin inventar tamaños:

| Campos | Significado |
|---|---|
| `source_columns`, `source_rows` | Tamaño real de la **ventana tmux**, sin status; no el de un pane individual |
| `presentation_columns`, `presentation_rows` | Canvas necesario para esa ventana y las filas de status de la auxiliar móvil |

Los cambios usan el mismo `attach_id` y la misma secuencia `seq` del flujo PTY.
Una geometría idéntica a la última publicada no se vuelve a emitir, aunque haya
otro `client-resized`: ajustar el PTY móvil al canvas no genera un bucle de avisos.
Un evento de geometría puede no contener `data`; no significa cierre. El cliente
aplica primero la geometría y después los bytes del mismo evento. Puede ajustar
su emulador y solicitar `pty_resize` al tamaño de presentación, sin cambiar la
ventana original. No debe recortar simplemente el rectángulo superior: en un PTY
demasiado alto tmux sitúa la barra de estado al final, tras las filas de relleno.
Si faltan estos campos, se conserva el comportamiento anterior.

Linux toma la geometría al confirmar el attach y mediante hooks `window-resized`,
`client-resized` y `after-set-option` instalados sólo en la auxiliar. El transporte
local/SSH existente recibe un marcador privado con nonce de 32 hexadecimales:
`RS UCPTY_GEOMETRY_<nonce>:<ancho>:<alto>:<status> US`, sin espacios; `RS` es 0x1e
y `US` es 0x1f. `status` es `off`, `on` o entre `2` y `5`. Los hooks capturan la tty
del cliente móvil al conectar, no la del cliente que posteriormente provoca un
resize. No se añaden hooks globales, conexiones SSH por evento ni órdenes al pane.
El adaptador elimina sólo sus marcadores válidos con un buffer acotado que
persiste entre lecturas, conserva íntegros los bytes VT/UTF-8 y publica los campos
anteriores; Android nunca debe interpretar este marcador interno. Un marcador
incompleto al cerrar, inválido o de otro nonce permanece como contenido original.
Un callback tardío cuya tty ya se cerró termina sin salida ni error de `run-shell`,
para que tmux no abra una vista de diagnóstico en un pane compartido. Un fallo
del bootstrap no confirma `READY` y el attach falla de forma cerrada.

Mac usa ese mismo marcador y los mismos hooks, con nonce propio por adjunto y
filtrado en su controlador de conexión. Su primera medida llega como evento
después del ACK (éste sigue acreditando el lanzamiento del cliente, no un
handshake SSH). Los avisos siguientes se ordenan con los bytes y se deduplican;
repetir attach puede incluir la última geometría conocida. La medición nunca
se sustituye por las dimensiones solicitadas por el teléfono.

No se cambia la ventana seleccionada del escritorio para alcanzar un pane
oculto: se selecciona sólo en la auxiliar. La sesión auxiliar y `active-pane`
aíslan las selecciones del PC. Después de conectar es un cliente tmux real:
si se elimina un pane por fuera de UniConnect, tmux puede seleccionar otro;
no se garantiza fijación perpetua a un pane eliminado. Se conserva la configuración
de ratón del destino original. El modo copia pertenece a tmux, no al historial
local del emulador ni a una nueva instancia del programa.

El adaptador de escritorio Linux conserva la selección al copiar con tmux
únicamente en sus servidores dedicados `uniconnect` y `uniconnect-local`: cambia
`MouseDragEnd1Pane` a `copy-pipe-no-clear` sólo si conserva el binding original
`copy-pipe-and-cancel`. Las tablas de teclas son del servidor; no se alteran
personalizaciones ni sockets ajenos. Esto no convierte la selección de tmux en
selección nativa de VTE ni resuelve por sí solo el menú contextual.
