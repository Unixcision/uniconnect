# Copiar texto en Linux

En una conexión tmux abierta, **Mayús + arrastrar con el botón izquierdo**
selecciona ahora el historial real de esa ventana. Manteniendo el clic por encima
o por debajo del terminal, la selección continúa desplazándose; al volver dentro
o soltar, el desplazamiento se detiene. Después, `Ctrl+Mayús+C` copia el rango y
devuelve el teclado al programa. `Esc` o **Salir de selección** cancelan sin copiar.

El historial de VTE no existe en la pantalla alternativa que usa tmux, aunque se
configure un límite de 50.000 líneas. El gesto se convierte en comandos de
selección dirigidos al pane resuelto, nunca en teclas o eventos de ratón para la
IA. El destino queda fijado por sesión, PID y geometría; los movimientos se
agrupan en un único trabajador local/SSH y Copiar espera al último movimiento.
No se recrean sesiones ni se cambia su límite de historial. Una ventana
desconectada conserva la selección local de su texto visible.

La acción **Copiar** (menú, menú contextual o `Ctrl+Mayús+C`) usa primero la
selección nativa de VTE. Cuando la selección pertenece a tmux, obtiene únicamente
la selección actual del panel de esa ventana mediante el transporte local o SSH,
la publica en el portapapeles de GTK y sale del modo copia para poder escribir.
Nunca usa como alternativa el último búfer global de otra ventana.

**Salir de selección** (`Ctrl+Mayús+Esc`, editable en Ajustes) cancela sin copiar
ni enviar caracteres a la IA. Está en el pie del terminal, el menú Editar, el menú
contextual y la paleta. Sólo afecta al panel de la ventana elegida. Como el modo
copia pertenece al pane tmux compartido, salir también libera ese pane para el
móvil; no cancela la selección de las demás ventanas.

La disponibilidad de Copiar no depende sólo de `VTE.get_has_selection()`: la
selección tmux se comprueba al ejecutar la acción. Las pruebas de MainWindow
verifican este paso por menú y acciones, además del adaptador de portapapeles.

Reconectar explícitamente un terminal ya abierto también abandona su modo copia;
no reinicia tmux ni la IA. No se envían teclas al agente para cancelar la selección.
Las operaciones SSH se ejecutan fuera del hilo gráfico.

Es una corrección del adaptador GTK/VTE de Linux solicitada específicamente para
Linux; macOS usa Ghostty/AppKit y no ejecuta este código. No cambia las políticas
globales de ratón, cifrado, geometría ni los identificadores de las conversaciones.

La regresión se prueba con portapapeles GTK real y tmux aislado en Ubuntu 22.04
(tmux 3.2a) y 24.04 (tmux 3.4), sin usar el portapapeles ni las sesiones del usuario.
Incluye un gesto XTest real de Mayús y clic mantenido a través de varias pantallas,
copia Unicode, escritura posterior y preservación de la selección de otro pane.
