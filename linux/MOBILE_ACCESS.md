# Acceso móvil personal por Tailscale

El botón del teléfono en la cabecera abre **Acceso móvil**. El listener está
desactivado inicialmente. Al activarlo, UniConnect verifica que `tailscale status
--json` esté conectado y que su IPv4 figure también en la interfaz `tailscale0`.
Solo escucha en esa dirección, puerto 58465; nunca en `0.0.0.0` ni en la LAN.
El sistema necesita los comandos `tailscale` e `ip`. Un fallo mantiene cerrado el
listener y aparece en el diálogo. No modifica la configuración de Tailscale.

Introduce esa IP en Android. La petición aparece en UniConnect con la IP observada
por el servidor: **Autorizar** permite el acceso y **Rechazar** lo bloquea. Hasta
autorizar, ni siquiera se muestra el árbol de espacios de trabajo. Un nombre,
una IP declarada en JSON o un antiguo token de Stack no conceden permisos.

La autorización se refiere al nodo Tailscale, no a una aplicación concreta:
cualquier proceso de ese dispositivo tiene el mismo acceso. Autoriza solo tus
equipos; revisa el permiso si se reasigna una IP. **Revocar acceso** cierra las
conexiones de ese dispositivo y retira sus informes de tamaño de terminal.
Los permisos y la identidad de máquina se guardan en `mobile-access.json`, privado
y con escritura atómica, dentro del directorio de estado de UniConnect. No contiene
contraseñas SSH. Una aprobación no se activa si falla su escritura.

Activar el listener es una decisión local de este equipo. Importar una configuración
o un archivo cifrado no incorpora `settings.mobileHostEnabled`: conserva su valor
local, incluso cuando todavía no existe y el acceso está desactivado por omisión.
Restaurar un punto de recuperación tampoco cambia esa decisión. Los dispositivos
autorizados de `mobile-access.json` no se importan con los espacios de trabajo.

## Qué comparte y qué no

- Usa el encuadre de `CMUXMobileCore`: longitud UInt32 big-endian y JSON UTF-8.
  No expone a la red el socket Unix privado de `control.py`.
- `mobile.workspace.list` lee los espacios y ventanas del modelo real, sin
  seleccionar otra caja en el escritorio. Envía nombres, IDs, tipo, carpeta y
  binding tmux; nunca comandos SSH ni credenciales.
- `mobile.terminal.input` escribe en la VTE que ya existe. Una superficie que
  todavía no está abierta en el escritorio devuelve `surface_unavailable`; una
  desconectada devuelve `process_exited`. Ninguna de esas lecturas crea una IA.
- La creación es explícita (`workspace.create` / `terminal.create`), requiere
  nombres y destino, y comparte la confirmación persistente de los diálogos GTK.
  SSH hereda credenciales de una caja existente; local recibe carpeta y agente.
  El resultado identifica la ventana creada, no afirma que su proceso ya esté
  preparado. El montaje del cliente sigue el flujo asíncrono existente.
- Replay captura con colores la pantalla del tmux **ya existente**, local o SSH,
  mediante `capture-pane -e -N`. Devuelve una cuadrícula completa
  `cmux.render-grid.v1` en `render_grid`, el mismo DTO que recibe Android de Mac,
  con estilos, cursor, tamaño y pantalla alternativa. No se adjunta, no crea
  otra sesión y no roba bytes a VTE. La lectura SSH puede requerir una conexión
  de control breve, limitada a una captura cada 750 ms por terminal; local, 250 ms.
  Las peticiones concurrentes se serializan antes de capturar y asignar revisión.
  Una caché de hasta ocho pantallas comparte las respuestas inmediatas entre
  clientes; un cambio de contenido o perfil de color obliga a una captura nueva.
- `terminal.updated` invalida la pantalla; Android debe pedir otro replay. No se
  publican deltas ni se emula una terminal Android a partir de escapes. Se anuncia
  `terminal.render_grid.v1` solo cuando está disponible la dependencia Unicode.
  Tampoco se anuncia el conjunto de
  acciones de caja `workspace.actions.v1`, todavía no implementado en este adaptador.
- Los informes `terminal.viewport` pertenecen a cada conexión/cliente y se
  eliminan al desconectar. Su efecto geométrico real depende de VTE/GTK y necesita
  aceptación visual en Linux; compilar Python no lo valida.
- `mobile.notifications.list` y `notification.created` usan el mismo historial
  persistente que la lista de notificaciones del escritorio, con cursor opaco,
  IDs estables, hasta 1000 entradas y lectura sin cambios de selección.

## Acciones del centro de notificaciones

El escritorio y `mobile.notifications.list` leen el mismo `notificationHistory`:
marcar o descartar no crea otro historial ni modifica sesiones tmux. Las acciones
globales pertenecen al catálogo `ACTIONS`, compartido por menús, paleta y Ajustes.

| Acción Linux | Atajo inicial | Ámbito |
|---|---|---|
| Ir a la última no leída | `Ctrl+Mayús+U` | Abre el destino exacto de la última notificación no leída cuya ventana sigue existiendo. |
| Marcar caja como leída/no leída | `Ctrl+Alt+U` | Caja activa; también en su menú contextual. |
| Marcar ventana como leída/no leída | Sin asignar | Terminal activa; también en el contextual de su pestaña. |
| Marcar todo como leído | Sin asignar | Historial y marcadores de todas las cajas. |
| Descartar todas las notificaciones | Sin asignar | Solo elimina el historial y sus marcadores; no cierra terminales. |

Los atajos se pueden cambiar en Ajustes (`settings.shortcuts`), igual que las
demás acciones Linux. Las etiquetas reflejan el estado real y los comandos sin
destino o sin elementos correspondientes quedan deshabilitados. Cada fila ofrece
Abrir, marcar leída/no leída y Descartar, en ese orden. Un destino cerrado no abre
otra caja como alternativa. La selección contextual no consume la notificación;
una marca manual de no leída se conserva al volver del menú hasta cambiar de
terminal. Si falla el guardado, se restauran historial y marcadores anteriores.

Esta adaptación completa las acciones ya existentes en macOS descritas en
`docs/MENUS.md`; no modifica el store ni los menús de Mac. Las pruebas esenciales
Linux están en `tests/test_notifications.py` y se ejecutan únicamente en CI.

## Límites y validación pendiente

Esta implementación **no demuestra paridad visual completa con Ghostty**:
no serializa todo el estado interno de VTE, imágenes inline, enlaces ni todos los
modos de entrada de una TUI. Las consolas antiguas sin tmux no ofrecen este replay.
La paleta ANSI de 16 colores se aplica explícitamente a VTE y se comparte con el
adaptador de captura; no se adivina la paleta predeterminada de la distribución.
Los cambios posteriores de paleta mediante OSC, anchos de celda decididos por una
versión de tmux diferente de Unicode 15.1, tabuladores personalizados, cursor con
otra forma y variantes de subrayado no se recuperan con fidelidad completa desde
`capture-pane`. El adaptador rechaza capturas con controles desconocidos o fuera
de límites: no inventa una pantalla ni usa una segunda sesión como alternativa.
Exige una superficie del escritorio abierta con su perfil de color conocido.
No cambia la política de recuperación del transporte Linux: una sesión guardada
ausente sigue el contrato de `transport.py`, no el de la implementación macOS.

`bash linux/install.sh --dependencies` instala GTK/VTE mediante los paquetes del
sistema y crea `linux/.venv` con `--system-site-packages`, donde instala únicamente
`wcwidth==0.2.13`. Ubuntu 24.04 distribuye una versión anterior que no cubre este
contrato Unicode. No modifica Python global ni necesita `--break-system-packages`.
Ejecuta el instalador como tu usuario: solo la instalación de paquetes usa `sudo`.
Si ya tienes los paquetes, `bash linux/install.sh` prepara el entorno privado y
los lanzadores. Si el entorno queda incompleto, el lanzador conserva el escritorio
con Python del sistema y el host no anuncia un renderer que no puede proporcionar.

Las pruebas en `tests/test_mobile.py` cubren framing fragmentado, aprobación,
fallos de persistencia, revocación, IDs explícitos, entrada en la superficie
existente, viewport por cliente, paginación, serialización de revisiones, cadencia,
paleta compartida y lectura de un tmux real aislado. `test_mobile_render_grid.py`
cubre SGR, colores indexados/RGB, caracteres anchos y combinados, ZWJ/VS16,
dibujos DEC y límites del DTO; Android usa la misma muestra de cuadrícula.
El caso real está limitado a CI y a un socket temporal exclusivo; nunca utiliza
sesiones del usuario. En esta entrega se ha comprobado la sintaxis Python, **no
se han ejecutado las pruebas localmente ni se ha validado Android contra Linux**.
Falta la prueba completa con GTK/VTE, Tailscale y el teléfono antes de afirmar
que el flujo de dos equipos está terminado.
