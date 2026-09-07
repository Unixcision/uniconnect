# Copiar y pegar en Linux

## Selección rápida

Mayús + arrastrar vuelve a usar la selección azul nativa de VTE. `Ctrl+Mayús+C`
copia y `Ctrl+Mayús+V` pega. Este gesto no activa el modo copia de tmux ni hace
peticiones SSH por movimiento. Sirve para el texto que VTE tiene disponible;
no puede recuperar por sí solo el historial remoto de la pantalla alternativa.

## Selecciones largas

Pulsa **Historial para copiar** en el pie del terminal, menú Editar, menú contextual
o paleta; también `Ctrl+Mayús+H`, configurable en Ajustes y `settings.shortcuts.show_history`.
Se abre una vista local de solo lectura con el historial retenido por ese pane
(hasta las últimas 50.000 líneas y 8 MiB). La lectura usa una sola operación SSH,
no entra en copy-mode, no crea búferes tmux ni envía entrada a la sesión.

Dentro de la vista puedes arrastrar normalmente, sin Mayús, hacia fuera del borde
superior o inferior para continuar la selección; también usar rueda, barra de
scroll y Mayús + clic. Copia con el botón **Copiar**, `Ctrl+C`, el atajo configurado
de Copiar o el menú contextual. La búsqueda se ejecuta con Intro. **Actualizar
historial** obtiene otra instantánea; no se actualiza sola mientras seleccionas.
**Volver al terminal** o `Esc` cierran la vista. La sesión sigue trabajando detrás.
El contenido no se guarda en archivos ni logs; se descarta al cerrar la vista.

## Portapapeles y VNC

Una copia explícita publica el texto en `CLIPBOARD` y `PRIMARY`, para consumidores
Linux que usan cualquiera de los dos. No se instala un sincronizador global ni
se copian automáticamente todas las salidas. VNC sigue encargándose del traslado
entre equipos: sus permisos de transferencia deben estar habilitados.

RealVNC documenta un límite de 256 KiB para copiar/pegar texto; por encima puede
pegar el contenido anterior. La vista avisa cuando la selección supera ese tamaño,
sin truncar el texto que sí se copia completo al portapapeles Linux. Si falla una
copia pequeña entre equipos, hay que comprobar también Viewer/Server, no solo tmux.

El pegado sigue usando `VTE.paste_text`, preservando bracketed paste cuando el
programa lo solicita. No se añade Intro automáticamente. Las imágenes conservan
su ruta de pegado/subida existente.

## Compatibilidad y validación

La selección naranja iniciada directamente en tmux conserva su exportación
explícita por Copiar, fijada al pane; nunca se usa el último búfer de otra ventana.
**Salir de selección** cancela ese modo sin enviar caracteres al agente. No hace
falta entrar en él para usar la nueva vista de historial.

Cambio específicamente Linux: macOS usa Ghostty/AppKit y no ejecuta este adaptador.
Se conservan el repositorio compartido, español, cifrado y los UUID de las sesiones.
Las pruebas se ejecutan en CI con GTK, portapapeles real, XTest y tmux; una SSH de
prueba con claves efímeras verifica lectura, selección larga, pegado y preservación
de pane/PID y del búfer ajeno. Nunca se usan sesiones ni portapapeles del usuario.

## Fuentes de la decisión

- [tmux: portapapeles, OSC 52 y limitaciones de VTE](https://github.com/tmux/tmux/wiki/Clipboard).
- [VTE: la pantalla alternativa no tiene scrollback local](https://gnome.pages.gitlab.gnome.org/vte/gtk3/method.Terminal.set_scrollback_lines.html).
- [tmux: capture-pane](https://man.openbsd.org/tmux.1#capture-pane).
- [GTK: selección y texto nativos](https://docs.gtk.org/gtk3/text-widget-overview.html).
- [RealVNC: transferencia de texto y límite documentado](https://help.realvnc.com/hc/en-us/articles/360002253738-Copying-and-Pasting-Text).
