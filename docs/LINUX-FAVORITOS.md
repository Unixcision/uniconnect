# Favoritos y orden en Linux

Un favorito reutiliza el campo `pinned` de las cajas y ventanas existentes. Las
cajas y ventanas fijadas aparecen primero, identificadas con una estrella. Dentro
de cada grupo se conserva el orden elegido; no se mezclan los grupos al mover.

En el menú **Caja** y en los menús de clic derecho se puede fijar o desfijar, subir,
bajar o llevar al principio de su grupo. Las pestañas también se pueden arrastrar
dentro de su panel. Las acciones de subir/bajar ventanas permiten ordenar la lista
completa, incluso cuando sus terminales están en paneles distintos: no trasladan
el terminal de panel. No se añaden atajos predeterminados; las nuevas acciones
están disponibles en la paleta y en los ajustes de atajos existentes.

Escritorio y móvil llaman a la misma operación de cambio y guardado. El contrato
de los RPC `mobile.workspace.update` y `mobile.terminal.update` se encuentra en
[la arquitectura compartida](UNICONNECT.md#favourites-and-order-mobile-contract-2026-09-08).
Linux anuncia `box_update` en `mobile.workspace.list`, devuelve la lista completa
y envía el aviso de cambio a los clientes conectados después de guardar.

La posición es base cero dentro del grupo resultante después de aplicar el
favorito; se recorta al extremo si está fuera del grupo. Repetir la misma petición
no invierte el favorito. Los cambios por ID no abren cajas guardadas ni cambian
el foco, la selección, los procesos tmux o las credenciales. Durante una operación
transaccional de cajas se responde `busy`. Si falla el guardado, se restaura el
modelo y el orden visible anterior.

`paneOrder` conserva por separado el orden geométrico de los paneles. Los estados
anteriores siguen siendo válidos: se deriva de la primera aparición de cada
`paneId` hasta la primera modificación de orden de ventanas. Así, reordenar la
lista no intercambia los paneles al volver a abrir la aplicación.

El estado se comparte entre un host y sus clientes; no fusiona cajas de distintas
instalaciones Mac/Linux. Android sin `box_update` usa preferencias locales y lo
indica; una prueba de esa ruta no valida los RPC del host. La validación Linux se
ejecuta en GitHub Actions sobre Ubuntu 22.04 y 24.04 con estado, pantalla y tmux
aislados. La implementación Mac pertenece al equipo Mac, no se valida con estos
resultados Linux. El copiado de historial no cambia con esta función.
