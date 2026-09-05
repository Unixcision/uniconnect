# UniConnect — menús y atajos

Este documento describe la superficie de menús implementada por UniConnect. Es el contrato de producto para la barra de menús, la paleta, los menús contextuales, el Dock y el icono de la barra de estado.

## Vocabulario y reglas

- **Caja** es una sesión de trabajo Local o SSH. En el código heredado sigue apareciendo como `Workspace`.
- **Ventana** es una terminal o sesión tmux dentro de una caja. En el código heredado también aparece como tab, surface o panel ID.
- **Panel** es una división visual que puede contener ventanas.
- **Nueva ventana** crea una terminal o sesión tmux dentro de la caja actual; no crea otra ventana principal de macOS. El código heredado todavía denomina `tab` o `surface` a este objeto.
- La barra sigue el orden de macOS: **UniConnect · Archivo · Edición · Visualización · Caja · Ventana · Ayuda**. No existe un menú Herramientas: sus acciones se reparten por función para no duplicarlas.
- Todos los iconos de menú son símbolos del sistema. Los separadores agrupan acciones por intención y las acciones destructivas quedan al final de cada menú contextual.
- Un atajo configurable siempre procede de `KeyboardShortcutSettings`; la barra, los contextuales y la paleta no mantienen copias independientes.
- Cerrar una ventana SSH desengancha el cliente, pero no mata tmux. **Terminar sesión tmux remota…** es una acción separada, explícita y confirmada.

## Barra de menús

### UniConnect

| Ítem | Atajo | Estado y ruta compartida |
|---|---:|---|
| Acerca de UniConnect | — | `AboutWindowController.show()` |
| Buscar actualizaciones… | — | Solo aparece para un feed HTTPS propio de Unixcision. Usa el updater de la aplicación. |
| Ajustes… | `⌘,` | `AppDelegate.openPreferencesWindow` |
| Abrir uniconnect.json | — | Abre la configuración propia. |
| Ajustes de Ghostty… | — | Abre la configuración del terminal. |
| Recargar configuración | `⇧⌘,` | Recarga Ghostty y `uniconnect.json`. |
| Bloquear | `⌃⌘L` | `UniConnectAppLock.lock()`; es la misma acción que Dock y barra de estado. |
| Bloquear automáticamente ▸ Desactivado · 5 · 15 · 30 · 60 min | — | Estado marcado con check; escribe `UniConnectAppLock.autoLockMinutes`. |
| Servicios, Ocultar, Ocultar otros, Mostrar todo | sistema | Propiedad de AppKit. |
| Salir de UniConnect | `⌘Q` | `NSApp.terminate`. |

No se ofrece *Hacer terminal por omisión* ni ninguna acción de cmux en este menú.

### Archivo

| Ítem | Atajo | Estado y ruta compartida |
|---|---:|---|
| Nueva caja… | `⌘N` | `AppDelegate.performNewWorkspaceAction`; muestra el flujo Local/SSH. |
| Nueva ventana | `⌘T` | `TabManager.newSurface`; en Local abre el selector Terminal/Claude/Codex/Agy/Grok/comando personalizado y en SSH pasa por el flujo de nombre y sesión tmux. Deshabilitada sin caja activa. |
| Reabrir la última cerrada | `⇧⌘T` | `AppDelegate.reopenMostRecentlyClosedItem`. Deshabilitada con historial vacío. |
| Cerradas recientemente ▸ | — | Hasta 40 entradas. Cada entrada permite **Reabrir** o **Eliminar definitivamente…**; al final aparece **Vaciar lista…**. |
| Cerrar ventana | `⌘W` | Ruta normal de cierre con confirmación e historial. |
| Cerrar otras ventanas del panel | `⌥⌘T` | Deshabilitada si el panel no contiene otras ventanas cerrables. |
| Cerrar caja | `⇧⌘W` | Ruta normal de cierre de caja con confirmación e historial. |
| Persistir ahora | `⌘S` | `UniConnectCoordinator.persistNow()`. |
| Último guardado: … | — | Fila informativa derivada del snapshot persistido. |
| Restaurar copia de seguridad… | — | `AppDelegate.restoreUniConnectRecoveryBackup`; la barra y la paleta llaman al mismo selector. |
| Importar configuración… | — | `UniConnectCoordinator.importConfiguration()`. |
| Migrar cajas desde cmux… | — | Migración manual y explícita; nunca ocurre al arrancar. |
| Exportar configuración… | — | `UniConnectCoordinator.exportConfiguration()`. |
| Guardar plantilla inicial… | — | `UniConnectCoordinator.saveSeedTemplate()`. |

Contrato de recuperación:

- la cadencia es de seis horas: hasta cuatro snapshots de recuperación por día, durante siete días y con un máximo de 28;
- el archivo de Release vive en `~/.uniconnect/backups` (los builds Debug aíslan su archivo por bundle ID);
- los snapshots viven fuera del historial de **Cerradas recientemente** y sobreviven a eliminar definitivamente una ventana o caja;
- la restauración solo admite JSON regulares dentro del archivo, crea un punto de recuperación previo e incorpora las cajas y ventanas recuperadas junto a las actuales;
- **Persistir ahora** se mantiene como acción explícita y no sustituye la rotación automática.

No hay *Nueva ventana principal*, `⇧⌘N`, *Abrir carpeta…*, `⌘O`, *Abrir en VS Code* ni una vía indirecta desde el clic secundario del botón `+`.

### Edición

AppKit mantiene Deshacer/Rehacer, Cortar, Copiar, Pegar, Pegar con el mismo estilo, Eliminar, Seleccionar todo, transformaciones, dictado y emojis. UniConnect añade:

| Ítem | Atajo | Estado y ruta compartida |
|---|---:|---|
| Buscar ▸ Buscar… | `⌘F` | Busca en el scrollback de la terminal enfocada. |
| Buscar siguiente | `⌘G` | `TabManager.findNext()`. |
| Buscar anterior | `⌥⌘G` | `TabManager.findPrevious()`. |
| Ocultar barra de búsqueda | `⌥⇧⌘F` | Deshabilitada si no hay búsqueda visible. |
| Usar selección para buscar | `⌘E` | Usa la selección de la terminal. |
| Enviar Ctrl-F al terminal | sin valor inicial | Escape configurable para aplicaciones TUI. |
| Modo de copia del terminal | `⇧⌘M` | Activa el modo de selección por teclado de Ghostty. |

*Buscar en directorio* y las acciones del navegador/barra derecha permanecen desvinculadas y fuera de la interfaz de UniConnect.

### Visualización

| Ítem | Atajo | Estado y ruta compartida |
|---|---:|---|
| Compactar barra lateral / Expandir barra lateral | `⌘⌥B` | Título e icono dinámicos. Cambia el estado de la ventana principal activa; el raíl nunca desaparece. |
| Paleta de comandos… | `⇧⌘P` | Abre la paleta ya filtrada para UniConnect. |
| Mostrar notificaciones | `⌘I` | Abre el centro de notificaciones. |
| Apariencia ▸ Sistema · Claro · Oscuro | — | Check sobre el valor activo. |
| Aumentar tamaño de fuente | `⌘=` | Solo con una terminal enfocada. |
| Reducir tamaño de fuente | `⌘-` | Solo con una terminal enfocada. |
| Tamaño de fuente por omisión | `⌘0` | Solo con una terminal enfocada. |
| Panel ▸ Dividir a la derecha | `⌘D` | Usa la misma creación de terminal/tmux que el resto de la app. |
| Panel ▸ Dividir hacia abajo | `⇧⌘D` | Igual que la anterior. |
| Panel ▸ Igualar divisiones | `⌃⌘=` | Deshabilitada sin divisiones. |
| Panel ▸ Ampliar / Restaurar panel | `⇧⌘↩` | Título dinámico; deshabilitada sin caja activa. |
| Panel ▸ Foco izquierda · derecha · arriba · abajo | `⌥⌘←/→/↑/↓` | Mueve el foco entre paneles. |
| Usar pantalla completa | sistema | Propiedad de AppKit; no se añade un duplicado. |

No hay *Focus Back/Forward*, historial de foco, controles de navegador, barra lateral derecha ni segundo atajo `⌘B`.

### Caja

| Ítem | Atajo | Estado y ruta compartida |
|---|---:|---|
| Renombrar caja… | `⇧⌘R` | Abre la misma ruta de renombrado de la paleta. |
| Editar conexión SSH… | — | Visible pero deshabilitada para cajas Local. |
| Color ▸ paleta · Elegir… · Quitar | — | Quitar se deshabilita sin color personalizado. |
| Fijar / Desfijar caja | — | `WorkspacePinCommands`; etiqueta e icono dinámicos. |
| Ir a la caja… | `⌘P` | Abre el selector de cajas. |
| Caja anterior / siguiente | `⌃⌘[` / `⌃⌘]` | Navegación por cajas. |
| Caja 1 … 9 | `⌘1` … `⌘9` | `9` selecciona la última; cada entrada se deshabilita si no existe destino. |
| Mover ▸ Arriba · Abajo · Al inicio | — | Estado según la posición actual. |
| Ventana anterior / siguiente | `⇧⌘[` / `⇧⌘]` | Navegación dentro de la caja. |
| Renombrar ventana… | configurable | Abre la misma ruta de renombrado de la paleta. |
| Reconectar esta ventana SSH ahora | `⌘R` | Fuerza el proceso SSH/tmux seleccionado aunque aún no figure como caído. |
| Reconectar ventanas SSH ahora | `⌃⌘R` | Fuerza todos los destinos SSH/tmux abiertos; deshabilitada sin destinos. |
| Terminar sesión tmux remota… | — | Solo se habilita para una ventana tmux SSH activa; confirmación destructiva. |
| Actualizar Claude ▸ En esta ventana | `⌃⌘U` | Solo el panel activo. |
| Actualizar Claude ▸ En esta caja | configurable | Todas las ventanas elegibles de la caja. |
| Actualizar Claude ▸ En todas las cajas… | configurable | Ámbito global con confirmación/progreso. |
| Ir a la última no leída | `⇧⌘U` | Deshabilitada sin notificaciones no leídas. |
| Marcar caja como leída / no leída | `⌥⌘U` | Etiqueta dinámica según la caja activa. |
| Marcar todo como leído | — | Deshabilitada sin elementos no leídos. |

### Ventana

Se conserva el menú estándar de AppKit: Minimizar (`⌘M`), Zoom, Traer todo al frente y la lista de ventanas. UniConnect no añade *Nueva ventana principal* ni Task Manager. Las ventanas auxiliares de Ajustes y Configuración siguen siendo ventanas estándar del sistema.

### Ayuda

| Ítem | Ruta |
|---|---|
| Manual de UniConnect | `docs/UNICONNECT.md` en `Unixcision/uniconnect` |
| Menús y atajos de teclado | Este documento |
| Atajos de teclado… | Ajustes › Atajos de teclado |
| Informar de un problema | Issues de `Unixcision/uniconnect` |

No quedan enlaces a la documentación, Discord, feedback ni issues de cmux.
El botón de Ayuda del pie de la barra lateral refleja estas mismas cuatro rutas, y el panel Acerca de apunta al repositorio y los commits de UniConnect.

## Otras superficies de comandos

### Paleta

La paleta expone las mismas rutas para bloquear, persistir, restaurar backup, reconectar, actualizar Claude por ámbito, importar, migrar, exportar y guardar plantilla. También conserva creación, navegación, renombrado, búsqueda y paneles útiles.

`ContentView.uniConnectAllowsCommandPaletteContribution` elimina las rutas heredadas de nueva ventana principal, abrir carpeta/VS Code, navegador, barra lateral derecha, Files/Find/Vault, Diff Viewer, Task Manager, mover una ventana a otra caja, actualizaciones cmux e identificadores internos.

### Dock

`AppDelegate.applicationDockMenu` contiene exactamente:

1. **Nueva caja…**
2. **Bloquear**

Ambos tienen icono del sistema. No existe *Nueva ventana*.

### Barra de estado

`MenuBarExtraController` muestra estado de no leídas, búsqueda global (`⌥⌘F`), acceso opcional a la ventana principal, hasta seis notificaciones recientes, centro de notificaciones (`⌘I`), última no leída (`⇧⌘U`), marcar todo, borrar todo, bloquear (`⌃⌘L`), reconectar (`⌃⌘R`), Ajustes y Salir (`⌘Q`). Los estados vacíos deshabilitan las acciones correspondientes.

## Menús contextuales

### Caja en la barra lateral expandida

`TabItemView.workspaceContextMenu` admite selección simple y múltiple:

- Renombrar (solo selección simple), editar conexión SSH (solo caja SSH), color, fijar/desfijar y grupo.
- Nueva ventana y actualizar Claude (solo selección simple); reconectar actúa sobre las ventanas SSH elegibles del conjunto y se deshabilita si no hay ninguna.
- Mover arriba/abajo/al inicio con enablement posicional.
- Marcar como leída/no leída según el estado real.
- Mostrar en Finder solo aparece para una caja Local.
- Cerrar caja(s), otras, inferiores y superiores forman el último grupo destructivo.

No contiene mover a otra ventana principal, IDs/enlaces internos, descripciones, navegador ni el SSH nativo heredado de cmux.

### Caja o grupo en el raíl compacto

`UniConnectRailTile` usa el mismo modelo de acciones del raíl para renombrar, editar SSH, plegar grupo, fijar, crear pestaña, reconectar, actualizar Claude, marcar leída/no leída y cerrar. Los badges distinguen Local/SSH, desconexión, no leídas y estado del bridge de notificaciones. **Cerrar caja** queda al final y usa rol destructivo.

### Cabecera de grupo

`SidebarWorkspaceGroupHeaderView` ofrece Renombrar, Plegar/Desplegar, Fijar/Desfijar, Editar configuración, Desagrupar conservando cajas y, al final, **Eliminar grupo (cerrar cajas)**. El contextual del botón `+` se limita a **Nueva caja en el grupo** y **Editar configuración**; no reexpone acciones configurables de abrir carpeta o VS Code.

### Barra de ventanas (Bonsplit)

`TabContextMenuBuilder` construye un `NSMenu` nativo con iconos y atajos proporcionados por el host:

- Renombrar y quitar nombre personalizado.
- Actualizar Claude y bifurcar conversación cuando la ventana es elegible. Los destinos de bifurcación se limitan a splits o una nueva pestaña dentro de la caja.
- Mover al panel izquierdo/derecho, ampliar/restaurar, fijar/desfijar y marcar leída/no leída.
- Cerrar ventana (`⌘W`), cerrar ventanas a izquierda/derecha y cerrar las demás.
- **Terminar sesión tmux remota…** es el último ítem cuando la ventana representa una sesión SSH tmux.

Se omiten mover a otra caja/ventana principal, terminal o navegador a la derecha, recargar/duplicar navegador, audio, IDs y bifurcar a una caja nueva.

### Contenido de terminal

`GhosttyNSView.menu(for:)` ofrece Copiar, Pegar, Nueva ventana (`⌘T`), Renombrar ventana, dividir a derecha/abajo, reiniciar terminal, actualizar Claude si existe una sesión conocida, forzar la reconexión de cualquier ventana SSH/tmux (también si está colgada pero aún no marcada como caída), cerrar ventana (`⌘W`) y, al final, terminar tmux remoto cuando procede. Copy/Paste y las acciones dependientes de contexto se deshabilitan correctamente.

### Notificación

Cada fila del centro de notificaciones ofrece Abrir, marcar leída/no leída y **Descartar** al final con rol destructivo. Las tres acciones usan símbolos del sistema y el mismo store que la barra y el menú Caja.

Los contextuales de Files, navegador, Vault/Sessions, Task Manager, extensiones y navegación de foco no forman parte de la superficie alcanzable de UniConnect.

## Atajos por omisión

| Atajo | Acción |
|---:|---|
| `⌘N` | Nueva caja… |
| `⌘T` | Nueva ventana dentro de la caja actual |
| `⇧⌘T` | Reabrir la última cerrada |
| `⌘W` / `⇧⌘W` | Cerrar ventana / caja |
| `⌥⌘T` | Cerrar otras ventanas del panel |
| `⌘R` | Reconectar ahora la ventana SSH/tmux seleccionada |
| `⇧⌘R` | Renombrar caja |
| `⌃⌘R` | Reconectar ahora todas las ventanas SSH/tmux |
| `⌘⌥B` | Compactar o expandir barra lateral |
| `⌘S` | Persistir ahora |
| `⌃⌘L` | Bloquear |
| `⇧⌘P` / `⌘P` | Paleta de comandos / selector de cajas |
| `⌘I` / `⇧⌘U` / `⌥⌘U` | Notificaciones / última no leída / alternar no leída |
| `⌃⌘U` | Actualizar Claude en esta ventana |
| `⌘D` / `⇧⌘D` | Dividir a derecha / abajo |
| `⇧⌘↩` / `⌃⌘=` | Ampliar panel / igualar divisiones |
| `⌥⌘←/→/↑/↓` | Mover foco entre paneles |
| `⌃⌘[` / `⌃⌘]` | Caja anterior / siguiente |
| `⇧⌘[` / `⇧⌘]` | Ventana anterior / siguiente |
| `⌘1…9` / `⌃1…9` | Caja / ventana por número |
| `⇧⌘G` / `⌃⌘.` | Agrupar selección / plegar grupo enfocado |
| `⌘F`, `⌘G`, `⌥⌘G`, `⌥⇧⌘F`, `⌘E` | Familia Buscar |
| `⇧⌘M` | Modo de copia del terminal |
| `⌘=`, `⌘-`, `⌘0` | Fuente de terminal |
| `⌥⌘F` | Búsqueda global |
| `⌃⌥⌘.` | Mostrar/ocultar UniConnect globalmente |
| `⌃N` / `⌃P` | Selección siguiente/anterior dentro de la paleta |

`⇧⌘N` queda libre y no crea una ventana. También están desvinculados y ocultos en Ajustes: `newWindow`, `closeWindow` (ventana principal), `openFolder`, `reopenPreviousSession`, `findInDirectory`, `focusHistoryBack/Forward`, todas las acciones de navegador/barra derecha/Diff Viewer, `saveFilePreview` y `markOldestUnreadAndJumpNext`.

## Propiedad del código y pruebas

| Superficie | Propietario |
|---|---|
| Barra principal y enablement | `Sources/cmuxApp.swift` |
| Cerradas recientemente | `Sources/cmuxApp+HistoryMenu.swift`, `Sources/ClosedItemHistory.swift` |
| Ayuda | `Sources/App/CmuxHelpCommands.swift`, `Sources/App/CmuxHelpResource.swift` |
| Paleta | `Sources/ContentView.swift`, `Sources/ContentView+RightSidebarCommandPalette.swift` |
| Atajos y visibilidad en Ajustes | `Sources/KeyboardShortcutSettings.swift`, `Packages/CmuxSettings`, `Packages/CmuxSettingsUI` |
| Dock, ventana activa y bloqueo de rutas heredadas | `Sources/AppDelegate.swift` |
| Barra de estado | `Sources/App/MenuBarExtraController.swift` |
| Caja expandida, notificaciones | `Sources/ContentView.swift`, `Sources/Update/UpdateTitlebarAccessory.swift` |
| Raíl compacto | `Sources/UniConnect/UniConnectRailTile.swift`, `Sources/UniConnect/UniConnectRailSidebar.swift` |
| Grupos | `Sources/SidebarWorkspaceGroupHeaderView.swift` |
| Ventana Bonsplit | `vendor/bonsplit/.../TabItemView.swift`, despacho en `Sources/Workspace.swift` |
| Terminal | `Sources/GhosttyTerminalView.swift` |
| Restauración de backups | `AppDelegate.restoreUniConnectRecoveryBackup`, `Sources/UniConnect/UniConnectRecoveryBackupRepository.swift`, `Sources/UniConnect/UniConnectRecoveryBackupPolicy.swift` |

Cobertura determinista asociada:

- `AppDelegateShortcutRoutingTests`: `⌘N`, ausencia de `⇧⌘N`, ventana activa, barra compacta y menú Dock.
- `WorkspaceUnitTests` y `KeyboardShortcutContextTests`: nombres Caja/Ventana, defaults, ocultación de acciones heredadas y contexto de atajos.
- `ShortcutUnbindingTests`: bindings eliminados y paso de teclas desvinculadas.
- `CommandPaletteShortcutCustomizationTests`: allowlist/denylist UniConnect y asociación de acciones configurables.
- `NotificationAndMenuBarTests`: snapshots, enablement, icono/badge y acciones de la barra de estado.
- `vendor/bonsplit/Tests/BonsplitTests`: orden, iconos, enablement, ausencia de movimientos entre cajas y tmux destructivo al final.
- `UniConnectRecoveryPersistenceTests`: cadencia de seis horas, límite 28/7 días, escritura atómica, privacidad de secretos, estado compacto y observación de mutaciones recuperables.

## Localización

Las cadenas de UniConnect están en `Resources/Localizable.xcstrings`, únicamente en español (`sourceLanguage: es`, `localizations.es`). macOS y Linux comparten ese catálogo; Android mantiene recursos españoles nativos. Las traducciones internas de dependencias como Bonsplit no cambian el idioma del producto. Las preferencias de idioma antiguas se normalizan a español sin modificar el idioma del sistema o de las sesiones.

Los títulos procedentes de configuración personalizada son datos del usuario y se muestran literalmente; todos los títulos propiedad de UniConnect usan claves localizadas.
