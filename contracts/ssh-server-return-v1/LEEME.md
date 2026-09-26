# ssh-server-return.v1 — rearmar la reconexión cuando vuelve el servidor

Mac y Linux reintentan unas pocas veces cuando se cae el ssh de una ventana (Mac: 3 intentos
en unos 24 s; Linux: 6 en 60 s) y después se rinden. Eso está bien para no machacar a un
servidor que rechaza la sesión, pero deja muertas para siempre las ventanas de un servidor que
simplemente no estaba accesible un rato.

Caso real (26-09-2026): el Mac se actualizó a macOS 27 y se reinició. UniConnect arrancó antes
de que Tailscale estuviera levantado. Las 4 ventanas del MINIPC (única caja por Tailscale)
quemaron sus intentos sin llegar al servidor (su `sshd` no registró ningún intento) y se
quedaron «· desconectado» aunque el MINIPC respondía minutos después.

## Regla

Al agotarse los reintentos automáticos de una ventana SSH:

1. Se comprueba si el servidor contesta: solo una conexión TCP a `host:puerto` del destino
   efectivo, sin iniciar sesión ni enviar credenciales (timeout 5 s).
2. Cada 30 s se repite mientras la ventana siga caída y esperando.
3. Cada comprobación se pasa por la política (`casos.json`):
   - **no contesta** → `esperar` y se recuerda que se vio caído;
   - **contesta tras haberse visto caído** → `rearmar` (la caída terminó);
   - **contesta sin haberse visto caído** → `rearmar` una sola vez por ventana (el fallo no
     era la red; un intento extra por si acaba de volver) y, la siguiente vez, `parar`.
4. `rearmar` = presupuesto de reintentos nuevo y reconexión solo a la sesión tmux que ya
   existe (nunca crea ni mata nada remoto).
5. El estado de la ventana se conserva entre esperas. Se borra cuando la ventana queda
   estable (Mac: comprobación de estabilidad; Linux: 60 s vivo), cuando alguien la reconecta
   a mano o cuando se cierra.

Una ventana que va por `ProxyJump` no contesta a la sonda directa: se queda en `esperar` y
nunca rearma sola, igual que antes de este contrato.

## Quién lo cumple

- Mac: `UniConnectSSHServerReturnPolicy` + `UniConnectSSHServerWaiter`
  (`cmuxTests/UniConnectSSHServerReturnTests.swift` lee este fichero).
- Linux: `linux/uniconnect/server_return.py` + `terminal.py`
  (`linux/tests/test_server_return.py` lee este fichero).
