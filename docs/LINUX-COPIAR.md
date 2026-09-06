# Copiar texto en Linux

La acción **Copiar** (menú, menú contextual o `Ctrl+Mayús+C`) usa primero la
selección nativa de VTE. Cuando la selección pertenece a tmux, obtiene únicamente
la selección actual del panel de esa ventana mediante el transporte local o SSH,
la publica en el portapapeles de GTK y sale del modo copia para poder escribir.
Nunca usa como alternativa el último búfer global de otra ventana.

Reconectar explícitamente un terminal ya abierto también abandona su modo copia;
no reinicia tmux ni la IA. No se envían teclas al agente para cancelar la selección.
Las operaciones SSH se ejecutan fuera del hilo gráfico.

Es una corrección del adaptador GTK/VTE de Linux solicitada específicamente para
Linux; macOS usa Ghostty/AppKit y no ejecuta este código. No cambia las políticas
de ratón, cifrado, geometría ni los identificadores de las conversaciones.

La regresión se prueba con portapapeles GTK real y tmux aislado en Ubuntu 22.04
(tmux 3.2a) y 24.04 (tmux 3.4), sin usar el portapapeles ni las sesiones del usuario.
