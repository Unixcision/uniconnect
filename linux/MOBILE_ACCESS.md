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
  mediante `capture-pane`. Devuelve un snapshot completo `tmux.active.vt`, cursor,
  tamaño y pantalla alternativa. No se adjunta, no crea otra sesión y no roba
  bytes a VTE. La lectura SSH puede requerir una conexión de control breve.
- `terminal.updated` invalida la pantalla; Android debe pedir otro replay. No se
  anuncian render-grid ni deltas de bytes. Tampoco se anuncia el conjunto de
  acciones de caja `workspace.actions.v1`, todavía no implementado en este adaptador.
- Los informes `terminal.viewport` pertenecen a cada conexión/cliente y se
  eliminan al desconectar. Su efecto geométrico real depende de VTE/GTK y necesita
  aceptación visual en Linux; compilar Python no lo valida.
- `mobile.notifications.list` y `notification.created` usan el mismo historial
  persistente que la lista de notificaciones del escritorio, con cursor opaco,
  IDs estables, hasta 1000 entradas y lectura sin cambios de selección.

## Límites y validación pendiente

Esta implementación **no demuestra paridad visual completa con Ghostty**:
no serializa todo el estado interno de VTE, imágenes inline, enlaces ni todos los
modos de entrada de una TUI. Las consolas antiguas sin tmux no ofrecen este replay.
No cambia la política de recuperación del transporte Linux: una sesión guardada
ausente sigue el contrato de `transport.py`, no el de la implementación macOS.

Las pruebas en `tests/test_mobile.py` cubren framing fragmentado, aprobación,
fallos de persistencia, revocación, IDs explícitos, entrada en la superficie
existente, viewport por cliente, paginación y lectura de un tmux real aislado.
El caso real está limitado a CI y a un socket temporal exclusivo; nunca utiliza
sesiones del usuario. En esta entrega se ha comprobado la sintaxis Python, **no
se han ejecutado las pruebas localmente ni se ha validado Android contra Linux**.
Falta la prueba completa con GTK/VTE, Tailscale y el teléfono antes de afirmar
que el flujo de dos equipos está terminado.
