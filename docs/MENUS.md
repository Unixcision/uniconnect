# UniConnect — Menús y atajos de teclado

Documento de referencia de la barra de menús, los menús contextuales, el menú del Dock y el menú de la barra de estado de UniConnect. Describe el estado **definitivo** decidido para la app (no el heredado de cmux) e indica, ítem por ítem, qué hace, con qué atajo y dónde vive en el código.

Convenciones de este documento:

- **Caja** = workspace de cmux con perfil UniConnect: Local (carpeta del Mac) o SSH (servidor).
- **Ventana** = pestaña/terminal dentro de una caja. En cajas SSH cada ventana es una sesión tmux con nombre; en cajas locales es una shell o una sesión de Claude reanudable. La palabra *pestaña* desaparece de la interfaz; *superficie*, *espacio de trabajo* y *workspace* también.
- **Panel** = división (split) dentro de una caja; una ventana vive en un panel.
- Los atajos son los valores por defecto; todos los que figuran con una `Action` se pueden cambiar en Ajustes › Atajos de teclado o en `uniconnect.json`.
- "Código" señala dónde está la acción hoy. Los ítems de menú en sí se construyen en `Sources/cmuxApp+UniConnectMenus.swift` (nuevo fichero que sustituye a los bloques `.commands` de `Sources/cmuxApp.swift`, a `Sources/cmuxApp+HistoryMenu.swift` y al `CommandMenu(\"UniConnect\")`).

## 1. Principios

1. **Pocos menús, los de siempre.** Barra de menús en el orden que fija la HIG de macOS: Apple · **UniConnect** · **Archivo** · **Edición** · **Visualización** · **Caja** · **Ventana** · **Ayuda**. El único menú propio es *Caja*, colocado donde la HIG sitúa los menús específicos de la app: entre Visualización y Ventana.
2. **Una app, una ventana.** No hay \"Nueva ventana\", \"Mover a ventana\", \"Restaurar sesión anterior\" ni nada que pueda abrir una segunda ventana principal (duplicaría cajas y engancharía dos veces las sesiones tmux).
3. **Sin navegador embebido, sin barra lateral derecha, sin abrir carpetas.** El navegador de cmux, el explorador de ficheros/Find/Sessions/Feed/Dock y \"Abrir carpeta\" no forman parte de UniConnect. Sus atajos se liberan o se reaprovechan.
4. **Cada atajo tiene exactamente un ítem de menú y ningún atajo se repite.** La tabla del apartado 12 es la fuente de verdad; un test la protege.
5. **Español en la interfaz.** Todas las cadenas pasan por `Resources/Localizable.xcstrings` (claves `menu.*`, `contextMenu.*`, `statusMenu.*`, `tab.*`, `dock.*`) con valor `en` y `es`. No quedan literales en castellano en el código.
6. **Reglas HIG aplicadas:** el menú de aplicación lleva Acerca de, actualizaciones, Ajustes (⌘,) y lo que afecta a la app entera (bloqueo); Archivo crea, abre/reabre, cierra, guarda e importa/exporta, en ese orden; Edición es el estándar más Buscar; Visualización solo cambia cómo se ve la ventana; Ventana queda tal cual lo genera AppKit; Ayuda es corta y apunta a documentación propia.

## 2. Menú UniConnect (menú de aplicación)

| Ítem | Atajo | Qué hace | Código |
|---|---|---|---|
| Acerca de UniConnect | — | Abre la ventana Acerca de (`cmux.about`). | `AboutWindowController.shared.show()` — `Sources/cmuxApp.swift:448` |
| Buscar actualizaciones… | — | Comprueba el feed Sparkle. **Solo se muestra si el feed es el de Unixcision** (`UpdateFeedPolicy.isUniConnectFeed`); mientras el feed sea el de cmux el ítem no aparece. | `AppDelegate.checkForUpdates` — `Sources/AppDelegate.swift:8239` |
| Instalar actualización y reiniciar | — | Aparece solo con una actualización descargada y el mismo gate de feed. | `InstallUpdateMenuItem` — `Packages/CmuxUpdaterUI/.../UpdatePill.swift:210` |
| — | | | |
| Ajustes… | ⌘, | Ventana de ajustes. | `openPreferencesWindow(debugSource: \"menu.cmdComma\")` — `Sources/AppDelegate.swift:8542` · Action `.openSettings` |
| Abrir uniconnect.json | — | Abre el JSON de configuración/atajos en el editor preferido. | `openCmuxSettingsFileInEditor()` — `Sources/cmuxApp.swift:5523` |
| Ajustes de Ghostty… | — | Abre la configuración del terminal embebido. | `GhosttyApp.shared.openConfigurationInTextEdit()` — `Sources/GhosttyTerminalView.swift:3735` |
| Recargar configuración | ⇧⌘, | Recarga Ghostty y `uniconnect.json`. Conserva la clave `menu.app.reloadConfiguration` porque `AppDelegate.installReloadConfigurationMenuItemAction` localiza el ítem por título. | `AppDelegate.reloadConfigurationMenuItem` — `Sources/AppDelegate.swift:12198-12249` · Action `.reloadConfiguration` |
| — | | | |
| Bloquear | ⌃⌘L | Pantalla de bloqueo con Touch ID. Los terminales, SSH y tmux siguen corriendo; se corta la captura de pantalla. | `UniConnectAppLock.shared.lock()` — `Sources/UniConnect/UniConnectAppLock.swift:107` · Action nueva `.lockApp` |
| Bloqueo automático por inactividad ▸ Desactivado · 5 min · 15 min · 30 min · 60 min | — | Minutos sin actividad del sistema antes de bloquear (0 = nunca). Marca de verificación nativa. | `UniConnectAppLock.autoLockMinutes` — `Sources/UniConnect/UniConnectAppLock.swift:55` |
| — | | | |
| Servicios ▸ | — | Sistema. | AppKit |
| Ocultar UniConnect · Ocultar otros · Mostrar todo | ⌘H · ⌥⌘H | Sistema. | AppKit |
| — | | | |
| Salir de UniConnect | ⌘Q | Cierra la app (el autosave ya ha persistido; la sesión tmux del servidor no se toca). | `NSApp.terminate(nil)` — `Sources/cmuxApp.swift:458` · Action `.quit` |

Fuera: *Hacer de UniConnect el terminal por defecto* (semántica de cmux como terminal de sistema).

## 3. Menú Archivo

| Ítem | Atajo | Qué hace | Código |
|---|---|---|---|
| Nueva caja… | ⌘N | Hoja \"Local o SSH\". Local pide carpeta, nombre y color; SSH pide nombre, comando de conexión (a la bóveda cifrada), color, y sondea/instala tmux. Mismo camino que el botón + de la barra lateral. | `AppDelegate.performNewWorkspaceAction` → `UniConnectCoordinator.interceptNewWorkspace` — `Sources/AppDelegate.swift:7007`, `Sources/UniConnect/UniConnectCoordinator.swift:49` · Action `.newTab` |
| Nueva ventana | ⌘T | En caja SSH: hoja \"nombre + sesión tmux\" y nueva ventana enganchada a esa sesión (`tmux new -A`). En caja Local: terminal nuevo en el panel enfocado. | `TabManager.newSurface` → `UniConnectCoordinator.interceptNewSurface` — `Sources/UniConnect/UniConnectCoordinator.swift:279` · Action `.newSurface` |
| — | | | |
| Reabrir la última cerrada | ⇧⌘T | Restaura la última ventana o caja cerrada (mismo historial que el submenú siguiente). | `AppDelegate.reopenMostRecentlyClosedItem` — `Sources/AppDelegate+ClosedItemHistory.swift:25` · Action `.reopenClosedBrowserPanel` (nombre heredado) |
| Cerradas recientemente ▸ | — | Hasta 40 entradas; cada una tiene submenú **Reabrir** / **Eliminar definitivamente…** (alerta; no toca la sesión tmux del servidor). Al final, **Vaciar lista…**. Vacío: \"No hay ventanas ni cajas cerradas\". | `ClosedItemHistoryStore.menuSnapshot(maxItemCount: 40)` — `Sources/ClosedItemHistory.swift:259`; reabrir `AppDelegate+ClosedItemHistory.swift:160`; eliminar `UniConnectCoordinator.deleteClosedItem`; vaciar `ClosedItemHistoryStore.removeAll()` |
| — | | | |
| Cerrar ventana | ⌘W | Cierra la ventana activa (con confirmación si hace falta). En SSH solo se desengancha: la sesión tmux sigue viva en el servidor. La ventana va a Cerradas recientemente. | `closePanelOrWindow()` — `Sources/cmuxApp.swift:1434` · Action `.closeTab` |
| Cerrar otras ventanas del panel | ⌥⌘T | Cierra las demás ventanas del panel enfocado. | `TabManager.closeOtherTabsInFocusedPaneWithConfirmation` — `Sources/TabManager.swift:5369` · Action `.closeOtherTabsInPane` |
| Cerrar caja | ⇧⌘W | Cierra la caja activa; va a Cerradas recientemente (con sus IDs tmux, sin secretos). | `closeTabOrWindow()` — `Sources/cmuxApp.swift:1447` · Action `.closeWorkspace` |
| — | | | |
| Persistir ahora | ⌘S | Escribe el snapshot de sesión y el backup cifrado (`backup.uc`, historial de 30) y muestra \"Persistido\" con *Mostrar en Finder*. | `UniConnectCoordinator.persistNow()` — `Sources/UniConnect/UniConnectCoordinator.swift:651` · Action nueva `.persistNow` |
| Último guardado: hh:mm:ss | — | Texto informativo (deshabilitado) con la hora del último snapshot. | `UniConnectCoordinator.lastSavedMenuLabel()` — `Sources/UniConnect/UniConnectCoordinator.swift:918` |
| — | | | |
| Importar configuración… | — | Abre un `.uc` cifrado, una semilla JSON o un mapa de conexiones en Markdown; previsualiza y crea cajas. | `UniConnectCoordinator.importConfiguration()` — `Sources/UniConnect/UniConnectCoordinator.swift:734` |
| Migrar cajas desde cmux… | — | Lee `session-com.cmuxterm.app.json` de cmux (solo lectura), previsualiza y crea las cajas. | `UniConnectCoordinator.migrateFromCmux()` — `Sources/UniConnect/UniConnectCoordinator.swift:621` |
| Exportar configuración… | — | Touch ID → fichero `.uc` (PBKDF2 + AES-256-GCM) con cajas, ventanas y comandos de conexión. | `UniConnectCoordinator.exportConfiguration()` — `Sources/UniConnect/UniConnectCoordinator.swift:684` |
| Guardar plantilla inicial… | — | Guarda `uniconnect-seed.json` (JSON plano, sin secretos cifrados) para arrancar otra máquina. | `UniConnectCoordinator.saveSeedTemplate()` — `Sources/UniConnect/UniConnectCoordinator.swift:905` |

Fuera: *Nueva ventana* (⇧⌘N), *Abrir carpeta…* (⌘O), *Abrir carpeta en VS Code (Inline)…*, el submenú *Workspace ▸* (sus ítems útiles están en Caja) y *Paleta de comandos* (ahora en Visualización). El atajo ⌘O deja de abrir nada: `AppDelegate.swift:13021` comprueba `UniConnectCoordinator.isEnabled`.

## 4. Menú Edición

Estándar de macOS (Deshacer ⌘Z, Rehacer ⇧⌘Z, Cortar ⌘X, Copiar ⌘C, Pegar ⌘V, Pegar con el mismo estilo ⌥⇧⌘V, Eliminar, Seleccionar todo ⌘A, Autorrelleno, Sustituciones, Transformaciones, Voz, Emojis y símbolos). Copiar/pegar actúan sobre el terminal Ghostty. Se añaden:

| Ítem | Atajo | Qué hace | Código |
|---|---|---|---|
| Buscar ▸ Buscar… | ⌘F | Barra de búsqueda en el scrollback del terminal. | `AppDelegate.performFindShortcutInActiveMainWindow` — `Sources/AppDelegate.swift:6797` · `.find` |
| Buscar ▸ Buscar siguiente | ⌘G | | `TabManager.findNext()` — `Sources/cmuxApp.swift:818` · `.findNext` |
| Buscar ▸ Buscar anterior | ⌥⌘G | | `TabManager.findPrevious()` — `Sources/cmuxApp.swift:823` · `.findPrevious` |
| Buscar ▸ Ocultar barra de búsqueda | ⌥⇧⌘F | Deshabilitado si la barra no está visible. | `TabManager.hideFind()` — `Sources/cmuxApp.swift:830` · `.hideFind` |
| Buscar ▸ Usar selección para buscar | ⌘E | | `TabManager.searchSelection()` — `Sources/cmuxApp.swift:838` · `.useSelectionForFind` |
| Buscar ▸ Enviar Ctrl-F al terminal | sin atajo (configurable) | Reenvía un Ctrl-F real al terminal (parada forzosa de Claude Code). | `TabManager.sendCtrlFToFocusedTerminal()` — `Sources/cmuxApp.swift:846` · `.sendCtrlFToTerminal` |
| Modo de copia del terminal | ⇧⌘M | Selección por teclado en el terminal. | Manejador de `.toggleTerminalCopyMode` en AppDelegate — `Sources/KeyboardShortcutSettings.swift:396` |

Fuera: *Buscar en el directorio…* (⇧⌘F; buscaba en el sistema de ficheros local vía la barra derecha).

## 5. Menú Visualización

| Ítem | Atajo | Qué hace | Código |
|---|---|---|---|
| Paleta de comandos… | ⇧⌘P | Paleta global. En UniConnect no lista *New Window*, *Open Folder*, *Open Folder in VS Code* ni *New Tab (Browser)*. | `NotificationCenter.post(.commandPaletteRequested)` — `Sources/cmuxApp.swift:761`; registro en `Sources/ContentView.swift:6847-6918` · `.commandPalette` |
| — | | | |
| Barra lateral compacta ✓ | ⌘B | Alterna entre el raíl de círculos de colores y la lista completa de cajas. La barra nunca se oculta. Un solo ítem y un solo atajo (antes había dos: ⌘B y ⌥⌘B). | `@AppStorage(\"uniconnect.sidebarCompact\")` — `Sources/cmuxApp.swift:56`, `Sources/ContentView.swift:2056`, `Sources/UniConnect/UniConnectRailSidebar.swift:16`; manejador de teclado `Sources/AppDelegate.swift:6344-6355` · `.toggleSidebar` |
| Mostrar notificaciones | ⌘I | Popover con las notificaciones de las cajas (avisos de Claude, campanas del terminal). | `AppDelegate.toggleNotificationsPopover(animated: false)` — `Sources/cmuxApp.swift:1451` · `.showNotifications` |
| Apariencia ▸ Sistema · Claro · Oscuro | — | Mismo ajuste que Ajustes › Apariencia. | `@AppStorage(AppearanceSettings.appearanceModeKey)` — `Sources/cmuxApp.swift:58`, `Sources/AppearanceSettings.swift:4-7` |
| — | | | |
| Aumentar tamaño de fuente | ⌘= | Terminal enfocado. | `ghostty_surface_binding_action(\"increase_font_size:1\")` — helper `Sources/GhosttyTerminalView.swift:7991` · Action nueva `.terminalFontSizeIncrease` |
| Reducir tamaño de fuente | ⌘- | | `\"decrease_font_size:1\"` · `.terminalFontSizeDecrease` |
| Tamaño de fuente por defecto | ⌘0 | | `\"reset_font_size\"` · `.terminalFontSizeReset` |
| — | | | |
| Panel ▸ Dividir a la derecha | ⌘D | Nuevo panel a la derecha. En cajas SSH pasa por la misma hoja tmux que Nueva ventana (antes abría una shell local). | `performSplitFromMenu(.right)` — `Sources/cmuxApp.swift:1205` · `.splitRight` |
| Panel ▸ Dividir hacia abajo | ⇧⌘D | | `performSplitFromMenu(.down)` · `.splitDown` |
| Panel ▸ Igualar divisiones | ⌃⌘= | | `TabManager.equalizeSplits` — `Sources/TabManager+EqualizeSplits.swift:5`, `Sources/cmuxApp+EqualizeSplitsMenu.swift:5` · `.equalizeSplits` |
| Panel ▸ Ampliar panel / Restaurar panel | ⇧⌘↩ | Título dinámico. | `Workspace.toggleSplitZoom(panelId:)` — `Sources/Workspace.swift:19632` · `.toggleSplitZoom` |
| Panel ▸ Foco a la izquierda · derecha · arriba · abajo | ⌥⌘← ⌥⌘→ ⌥⌘↑ ⌥⌘↓ | Mueve el foco entre paneles. | Manejadores de `.focusLeft/.focusRight/.focusUp/.focusDown` — `Sources/KeyboardShortcutSettings.swift:371-377` |
| — | | | |
| Usar pantalla completa | ⌃⌘F (fn-F) | Ítem automático de AppKit; se elimina el duplicado propio. | AppKit |

Fuera: barra lateral derecha (⌥⌘B, ⇧⌘E), *Siguiente/Anterior superficie* (ahora Ventana siguiente/anterior en Caja), *Caja 1…9* (en Caja), todo lo del navegador (Atrás, Adelante, Recargar página, Herramientas de desarrollo, Consola JavaScript, React Grab, Modo enfoque, zoom, Borrar historial, Importar datos, Dividir navegador), *Alternar pantalla completa* propio y los duplicados de notificaciones.

## 6. Menú Caja

Actúa sobre la caja activa y sus ventanas. Es el único menú propio y va entre Visualización y Ventana.

| Ítem | Atajo | Qué hace | Código |
|---|---|---|---|
| Renombrar caja… | ⇧⌘R | Nombre de la caja (se persiste y restaura). | `AppDelegate.requestRenameWorkspaceViaCommandPalette()` — `Sources/AppDelegate.swift:14491` · `.renameWorkspace` |
| Editar conexión SSH… | — | Touch ID → editor del comando de conexión de la bóveda. Deshabilitado en cajas Local. | `UniConnectCoordinator.editConnection(for:)` — `Sources/UniConnect/UniConnectCoordinator.swift:238` |
| Color ▸ paleta · Elegir color personalizado… · Quitar color | — | Color de la caja (círculo del raíl y fila). | `applyTabColor` / `promptCustomColor` — `Sources/ContentView.swift:16214-16243` |
| Fijar caja / Desfijar caja | — | Fija la caja arriba de la lista. | `WorkspacePinCommands` — `Sources/WorkspaceActionDispatcher.swift:117-135`, `Sources/cmuxApp.swift:1324` |
| — | | | |
| Ir a la caja… | ⌘P | Selector rápido de cajas. | `NotificationCenter.post(.commandPaletteSwitcherRequested)` — `Sources/cmuxApp.swift:756` · `.goToWorkspace` |
| Caja anterior | ⌃⌘[ | | `TabManager.selectPreviousTab()` — `Sources/TabManager.swift:6760` · `.prevSidebarTab` |
| Caja siguiente | ⌃⌘] | | `TabManager.selectNextTab()` — `Sources/TabManager.swift:6740` · `.nextSidebarTab` |
| Caja 1 … Caja 9 | ⌘1 … ⌘9 | ⌘9 = última caja. | `WorkspaceShortcutMapper.workspaceIndex` — `Sources/App/TerminalDirectoryOpenSupport.swift:774`, `Sources/cmuxApp.swift:1091` · `.selectWorkspaceByNumber` |
| Mover ▸ Arriba · Abajo · Al inicio | — | Reordena la caja en la lista (el orden se persiste). | `moveSelectedWorkspace(in:by:)`, `moveSelectedWorkspaceToTop` — `Sources/cmuxApp.swift:1347-1357` |
| — | | | |
| Ventana anterior | ⇧⌘[ | Ventana anterior dentro de la caja. | `TabManager.selectPreviousSurface()` — `Sources/TabManager.swift:6937` · `.prevSurface` |
| Ventana siguiente | ⇧⌘] | | `TabManager.selectNextSurface()` — `Sources/TabManager.swift:6932` · `.nextSurface` |
| Renombrar ventana… | ⌘R | Solo el nombre local; la sesión tmux conserva su ID. | `Workspace.promptRenamePanel(tabId:)` — `Sources/Workspace.swift:19569` · `.renameTab` |
| — | | | |
| Reconectar ventanas caídas | ⌃⌘R | Vuelve a enganchar todas las ventanas marcadas *· desconectada* (0,4 s entre clientes ssh). | `UniConnectCoordinator.reconnectAllDisconnected()` — `Sources/UniConnect/UniConnectCoordinator.swift:450` · Action nueva `.reconnectDroppedWindows` |
| Terminar sesión tmux remota… | — | Único sitio que ejecuta `tmux kill-session` en el servidor, tras confirmación crítica; después cierra la ventana. Deshabilitado si la ventana activa no es tmux de una caja SSH. | `UniConnectCoordinator.terminateRemoteTmuxSession(in:)` — `Sources/UniConnect/UniConnectCoordinator.swift:935` |
| Actualizar Claude ▸ En esta ventana | ⌃⌘U | Ver apartado 11. | `UniConnectClaudeUpdater.run(.window)` — `Sources/UniConnect/UniConnectClaudeUpdater.swift` (nuevo) · Action nueva `.updateClaudeInWindow` |
| Actualizar Claude ▸ En esta caja | — | Ver apartado 11. Confirmación previa. | `run(.box)` · `.updateClaudeInBox` |
| Actualizar Claude ▸ En todas las cajas… | — | Ver apartado 11. Confirmación previa con recuento. | `run(.all)` · `.updateClaudeEverywhere` |
| — | | | |
| Ir a la última no leída | ⇧⌘U | Salta a la caja/ventana con la notificación no leída más reciente. Deshabilitado sin no leídas. | `AppDelegate.jumpToLatestUnread()` — `Sources/AppDelegate.swift:11746` · `.jumpToUnread` |
| Marcar caja como leída / como no leída | ⌥⌘U | Título dinámico según el estado de la caja activa. | `AppDelegate.toggleFocusedNotificationUnread()` — `Sources/AppDelegate.swift:11847` · `.toggleUnread` |
| Marcar todo como leído | — | | `TerminalNotificationStore.markAllRead()` — `Sources/TerminalNotificationStore.swift:1768` |

## 7. Menú Ventana

Solo lo que genera AppKit: Minimizar (⌘M), Zoom, Traer todo al frente y la lista de ventanas. Las escenas `Window` de Ajustes y Config llevan `.commandsRemoved()` para no aparecer en la lista. Fuera: *Task Manager…* (monitor de procesos locales de cmux).

## 8. Menú Ayuda

| Ítem | Qué hace | Código |
|---|---|---|
| Manual de UniConnect | Abre `docs/UNICONNECT.md` en GitHub (Unixcision/uniconnect, rama uniconnect). | `Sources/App/CmuxHelpCommands.swift`, `Sources/App/CmuxHelpResource.swift` |
| Menús y atajos de teclado | Abre este documento (`docs/MENUS.md`). | idem |
| — | | |
| Atajos de teclado… | Ajustes › Atajos de teclado. | `openPreferencesWindow(navigationTarget: .keyboardShortcuts)` — `Sources/App/CmuxHelpCommands.swift:28-30` |
| — | | |
| Informar de un problema | `https://github.com/Unixcision/uniconnect/issues` (antes apuntaba a manaflow-ai/cmux). | `CmuxHelpResource.swift:99` |

AppKit añade el campo *Buscar*. Fuera: los 15 enlaces de documentación de cmux (todos apuntaban al mismo fichero), *Send Feedback* (enviaba a manaflow), *Discord* (comunidad de cmux) y el *Check for Updates* duplicado.

## 9. Menú del Dock

`AppDelegate.applicationDockMenu` (`Sources/AppDelegate.swift:6884`) devuelve dos ítems: **Nueva caja…** (`performNewWorkspaceAction(debugSource: \"dock.newBox\")`) y **Bloquear** (`UniConnectAppLock.shared.lock()`). Nunca *Nueva ventana*.

## 10. Menú de la barra de estado

`Sources/App/MenuBarExtraController.swift`; se instala si `MenuBarExtraSettings.shouldInstallMenuBarExtra`.

| Ítem | Atajo | Qué hace |
|---|---|---|
| Sin notificaciones no leídas / N no leídas | — | Cabecera informativa. Tooltip del icono: \"UniConnect: N notificaciones no leídas\" (antes \"cmux: …\"). |
| Buscar en todas las cajas… | ⌥⌘F | Paleta de búsqueda global (`GlobalSearchCoordinator`). Action `.globalSearch`. |
| Mostrar UniConnect | — | Solo en modo solo-barra-de-menús. |
| [notificaciones recientes] | — | Una línea por notificación; clic → salta a su caja/ventana. |
| Mostrar notificaciones | ⌘I | |
| Ir a la última no leída | ⇧⌘U | |
| Marcar todo como leído · Borrar todo | — | |
| — | | |
| Bloquear | ⌃⌘L | Nuevo. |
| Reconectar ventanas caídas | ⌃⌘R | Nuevo. |
| — | | |
| Ajustes… | — | Misma clave que el menú de aplicación (antes \"Preferences…\"). |
| — | | |
| Salir de UniConnect | ⌘Q | |

Fuera: *Task Manager…* y *Buscar actualizaciones…*.

## 11. Actualizar Claude

Menú Caja › Actualizar Claude ▸, contextual de caja (*Actualizar Claude en esta caja*) y contextual de ventana (*Actualizar Claude en esta ventana*, ⌃⌘U). Implementado en `Sources/UniConnect/UniConnectClaudeUpdater.swift` (nuevo).

**Ámbitos**

- **En esta ventana** (⌃⌘U): la ventana activa.
- **En esta caja**: todas las ventanas de la caja activa. Pide confirmación listando las ventanas afectadas.
- **En todas las cajas…**: todas las cajas abiertas. Pide confirmación con el recuento de hosts y ventanas y muestra progreso.

**Qué hace, por host (una sola vez por host aunque haya varias ventanas):**

- Caja Local: `/bin/zsh -lc 'claude --version; claude update; claude --version'` en un `Process` oculto.
- Caja SSH: `<comando de conexión> -T 'claude --version; claude update; claude --version'` construido con `UniConnectSSH.injectingOptions([\"-T\"] + baseClientOptions, into:)` y `shellQuote`, exactamente el camino de *Terminar sesión tmux remota* (`UniConnectCoordinator.swift:952-961`). Un host = un `credentialId`.
- La salida completa va a `~/Library/Application Support/UniConnect/logs/claude-update.log`.

**Después, por ventana del ámbito en la que corre Claude** (las ventanas sin Claude no se tocan):

- Local: si la ventana tiene sesión conocida (`uniConnectClaudeSessionsByPanelId` o el detector de agentes `forkableAgentSnapshot`), se cierra el panel y se recrea en el mismo sitio con el lanzador de reanudación que ya usa la restauración al arrancar: `cd <carpeta> && exec claude --dangerously-skip-permissions --resume <id>` (`UniConnectSSH.claudeResumeCommandLine`, `Workspace.uniConnectRestoredStartupCommand` en `UniConnectCoordinator.swift:1044`). Sin sesión conocida solo se actualiza el host y se avisa.
- SSH (tmux): `tmux display -p -t <sesión> '#{pane_current_command}'`; si es `claude`/`node` se envía `tmux send-keys -t <sesión> C-c` dos veces (salida limpia de Claude Code), se esperan 2 s y se envía `claude --dangerously-skip-permissions --continue` + Enter, que retoma la última conversación de esa carpeta. La sesión tmux nunca se mata.

**Resultado**: aviso con versión antes/después por host, ventanas reiniciadas y errores humanizados (`humanizeSSHFailure`). El ID de sesión de Claude no se pierde en ningún caso.

## 12. Tabla de atajos (sin colisiones)

| Atajo | Acción | Menú |
|---|---|---|
| ⌘, | Ajustes… | UniConnect |
| ⇧⌘, | Recargar configuración | UniConnect |
| ⌃⌘L | Bloquear | UniConnect · Dock · barra de estado |
| ⌘H · ⌥⌘H | Ocultar UniConnect · Ocultar otros | UniConnect (sistema) |
| ⌘Q | Salir de UniConnect | UniConnect |
| ⌘N | Nueva caja… | Archivo |
| ⌘T | Nueva ventana | Archivo |
| ⇧⌘T | Reabrir la última cerrada | Archivo |
| ⌘W | Cerrar ventana | Archivo |
| ⌥⌘T | Cerrar otras ventanas del panel | Archivo |
| ⇧⌘W | Cerrar caja | Archivo · contextual de caja |
| ⌘S | Persistir ahora | Archivo |
| ⌘Z ⇧⌘Z ⌘X ⌘C ⌘V ⌥⇧⌘V ⌘A | Edición estándar | Edición (sistema) |
| ⌘F | Buscar… | Edición › Buscar |
| ⌘G | Buscar siguiente | Edición › Buscar |
| ⌥⌘G | Buscar anterior | Edición › Buscar |
| ⌥⇧⌘F | Ocultar barra de búsqueda | Edición › Buscar |
| ⌘E | Usar selección para buscar | Edición › Buscar |
| ⇧⌘M | Modo de copia del terminal | Edición |
| ⇧⌘P | Paleta de comandos… | Visualización |
| ⌘B | Barra lateral compacta | Visualización |
| ⌘I | Mostrar notificaciones | Visualización · barra de estado |
| ⌘= · ⌘- · ⌘0 | Tamaño de fuente: aumentar · reducir · por defecto | Visualización |
| ⌘D · ⇧⌘D | Dividir a la derecha · hacia abajo | Visualización › Panel |
| ⌃⌘= | Igualar divisiones | Visualización › Panel |
| ⇧⌘↩ | Ampliar / Restaurar panel | Visualización › Panel · contextual de ventana |
| ⌥⌘← → ↑ ↓ | Foco al panel izquierdo / derecho / superior / inferior | Visualización › Panel |
| ⌃⌘F (fn-F) | Usar pantalla completa | Visualización (sistema) |
| ⇧⌘R | Renombrar caja… | Caja · contextual de caja |
| ⌘P | Ir a la caja… | Caja |
| ⌃⌘[ · ⌃⌘] | Caja anterior · siguiente | Caja |
| ⌘1 … ⌘9 | Caja 1 … 9 (9 = última) | Caja |
| ⇧⌘[ · ⇧⌘] | Ventana anterior · siguiente | Caja |
| ⌃1 … ⌃9 | Ventana 1 … 9 de la caja | (sin ítem; Action heredada `.selectSurfaceByNumber`) |
| ⌘R | Renombrar ventana… | Caja · contextual de ventana |
| ⌃⌘R | Reconectar ventanas caídas | Caja · barra de estado |
| ⌃⌘U | Actualizar Claude › En esta ventana | Caja · contextual de ventana |
| ⇧⌘U | Ir a la última no leída | Caja · barra de estado |
| ⌥⌘U | Marcar caja como leída / no leída | Caja |
| ⌘M | Minimizar | Ventana (sistema) |
| ⌥⌘F | Buscar en todas las cajas… | barra de estado (`.globalSearch`) |
| ⌃⌥⌘. | Mostrar/ocultar UniConnect | hotkey global (`.showHideAllWindows`) |
| ⇧⌘G | Nuevo grupo desde la selección | contextual de caja (`.groupSelectedWorkspaces`) |
| ⌃⌘. | Plegar/desplegar el grupo de la caja activa | (sin ítem; `.toggleFocusedWorkspaceGroupCollapsed`) |
| ⌃N · ⌃P | Siguiente · anterior en la paleta | solo con la paleta abierta |
| ⌘? | Buscar en Ayuda | Ayuda (sistema) |

Libres a propósito: ⌥⌘R, ⌘[ ⌘], ⌘L ⇧⌘L, ⌘O ⇧⌘O, ⇧⌘N, ⌥⌘B, ⇧⌘E, ⌥⌘E, ⌥⌘I, ⌥⌘C, ⌥⌘D ⇧⌥⌘D, ⌥⌘↩, ⌃⌘W, ⌥⌘S, ⇧⌘F.

Acciones heredadas de cmux que quedan **desvinculadas** en UniConnect (siguen en el enum y son configurables, pero Ajustes no las lista): `newWindow`, `closeWindow`, `openFolder`, `reopenPreviousSession`, `findInDirectory`, `focusRightSidebar`, `switchRightSidebarTo*`, `toggleRightSidebar`, `focusHistoryBack/Forward`, `editWorkspaceDescription`, `saveFilePreview`, `openBrowser`, `focusBrowserAddressBar`, `browserBack/Forward/Reload`, `browserZoom*`, `markdownZoom*`, `toggleBrowserDeveloperTools`, `showBrowserJavaScriptConsole`, `toggleBrowserFocusMode`, `toggleReactGrab`, `openDiffViewer`, `diffViewer*`, `splitBrowserRight/Down`, `markOldestUnreadAndJumpNext`. La comprobación de que ningún par de acciones vinculadas comparte atajo es un test de `UniConnectTests`.

## 13. Menús contextuales

### 13.1 Fila de caja (barra lateral expandida)

`Sources/ContentView.swift:16095-16357` (`TabItemView.workspaceContextMenu`). Soporta multiselección (títulos en plural). En el raíl compacto no hay menú contextual.

| Ítem | Atajo | Qué hace |
|---|---|---|
| Renombrar caja… | ⇧⌘R | `promptRename()` |
| Editar conexión SSH… | — | Solo cajas SSH, selección simple. `UniConnectCoordinator.editConnection(for:)` |
| Color ▸ | — | `applyTabColor` |
| Fijar caja(s) / Desfijar caja(s) | — | `WorkspaceActionDispatcher.performPinAction` |
| Grupo ▸ Nuevo grupo desde… (⇧⌘G) · Mover al grupo ▸ · Quitar del grupo | ⇧⌘G | `Sources/TabItemView+WorkspaceGroups.swift:5-70` |
| — | | |
| Nueva ventana | — | Selecciona la caja y llama a `interceptNewSurface` / `newSurface()` |
| Reconectar ventanas caídas de esta caja | — | `UniConnectCoordinator.reconnectDisconnected(in:)`; deshabilitado si no hay ventanas caídas |
| Actualizar Claude en esta caja | — | `UniConnectClaudeUpdater.run(.box)` |
| — | | |
| Mover arriba · Mover abajo · Mover al inicio | — | `reorderWorkspace`, `moveTabsToTop` |
| — | | |
| Marcar caja(s) como leída(s) / no leída(s) | — | `markTabsRead` / `markTabsUnread` |
| — | | |
| Mostrar en Finder | — | Solo cajas Local (oculto en SSH). `WorkspaceFinderDirectoryResolver` |
| — | | |
| Cerrar caja(s) | ⇧⌘W | `closeTabs(targetIds, allowPinned: true)` |
| Cerrar otras cajas · Cerrar cajas inferiores · Cerrar cajas superiores | — | `closeOtherTabs` / `closeTabsBelow` / `closeTabsAbove`; van a Cerradas recientemente, tmux intacto |

Fuera: *Mover a ventana ▸*, *Copiar ID / enlace* (API socket de cmux), *Copiar error SSH*, *Reconectar / Desconectar workspace* (SSH nativo de cmux, no el tmux de UniConnect), *Editar / Borrar descripción*, *Eliminar nombre personalizado*, *Borrar última notificación*.

### 13.2 Ventana (pestaña de la barra Bonsplit encima del panel)

`vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabItemView.swift:793-1085` construye el menú; `Sources/Workspace.swift:19567` (`splitTabBar(_:didRequestTabContextAction:)`) lo despacha; `Workspace.buildContextMenuShortcuts` (`Sources/Workspace.swift:16763`) pone los atajos. `TabContextAction` (`vendor/bonsplit/.../Public/Types/TabContextAction.swift`) gana los casos `updateClaude` y `terminateRemoteTmux`.

| Ítem | Atajo | Qué hace |
|---|---|---|
| Renombrar ventana… | ⌘R | `promptRenamePanel(tabId:)` |
| Quitar nombre personalizado | — | `setPanelCustomTitle(nil)` |
| — | | |
| Actualizar Claude en esta ventana | ⌃⌘U | `UniConnectClaudeUpdater.run(.window)` |
| Terminar sesión tmux remota… | — | Solo ventanas tmux de cajas SSH. `terminateRemoteTmuxSession(in:panelId:)` |
| — | | |
| Cerrar ventanas a la izquierda · a la derecha · Cerrar otras ventanas | — | `closeTabsFromContextMenu` (respeta fijadas) |
| — | | |
| Mover al panel izquierdo · derecho | — | Solo con splits. `moveSurfaceToAdjacentPane` |
| Ampliar panel / Restaurar panel | ⇧⌘↩ | `toggleSplitZoom` |
| Fijar ventana / Desfijar ventana | — | `setPanelPinned` |
| Marcar ventana como leída / no leída | — | `markPanelRead` / `markPanelUnread` |
| Bifurcar conversación · Bifurcar conversación en ▸ (división derecha · izquierda · arriba · abajo · nueva ventana) | — | Solo cajas Local con Claude detectado. `handleForkConversationContextAction` (`claude --resume --fork-session`) |

Fuera: *Mover pestaña ▸* (a otra caja / a caja nueva: rompe caja = servidor), *Nueva pestaña de terminal a la derecha* (en cajas SSH abría una shell local sin tmux), *Nueva pestaña de navegador*, *Silenciar / Recargar / Duplicar*, *Copiar IDs*, destino *Bifurcar a nueva caja*.

## 14. Lo que desaparece respecto a cmux y por qué

- **Segunda ventana** por cualquier vía: Nueva ventana (⇧⌘N), Mover a ventana ▸, Restaurar sesión anterior (⇧⌘O), Task Manager, lista de ventanas de Ajustes/Config. UniConnect restaura al arrancar y engancha cada sesión tmux una vez.
- **Abrir carpeta / VS Code**: la carpeta de una caja Local se elige al crearla. Se cierra la fuga por la que ⌘O seguía abriendo el panel con el ítem oculto.
- **Navegador embebido y barra lateral derecha** (Files, Find, Sessions, Feed, Dock): 14 ítems de Visualización, 2 de Edición, 4 del contextual de ventana y sus atajos.
- **Menú Historial**: el historial de foco entre panes es jerga de cmux (la barra ya oculta sus flechas); lo útil (reabrir cerradas) vive en Archivo.
- **Menú Notificaciones**: se reparte entre Visualización (mostrar) y Caja (leída/no leída, ir a la última); la lista de recientes está en el popover y en la barra de estado.
- **Menú UniConnect propio**: se disuelve en los menús estándar; *Cerradas…* (menú emergente) pasa a ser un submenú normal de Archivo.
- **Ayuda de cmux**: docs, Discord, feedback a manaflow, terminal por defecto.
- **Telemetría de cmux**: *Trigger Sentry Test Crash* y el menú *Update Pill* (solo DEBUG).
- **VM / backend cloud**: no tenía ítems de menú; nada que quitar.

## 15. Localización

Claves nuevas (en + es) en `Resources/Localizable.xcstrings`: `menu.box.*`, `menu.file.newBox`, `menu.file.newWindowInBox`, `menu.file.recentlyClosed.*`, `menu.file.closeWindow`, `menu.file.closeBox`, `menu.file.persistNow`, `menu.file.lastSaved`, `menu.file.importConfiguration`, `menu.file.migrateFromCmux`, `menu.file.exportConfiguration`, `menu.file.saveSeedTemplate`, `menu.app.lock`, `menu.app.autoLock.*`, `menu.view.compactSidebar`, `menu.view.appearance*`, `menu.view.font*`, `menu.view.pane*`, `menu.edit.terminalCopyMode`, `menu.help.manual`, `menu.help.menusAndShortcuts`, `menu.help.reportIssue`, `statusMenu.searchAllBoxes`, `statusMenu.lock`, `statusMenu.reconnect`, `contextMenu.editSSHConnection`, `contextMenu.newWindowInBox`, `contextMenu.reconnectBoxWindows`, `contextMenu.updateClaudeInBox`, `tab.updateClaude`, `tab.terminateRemoteTmux`, `dock.newBox`, `dock.lock`. Corregidas: `menu.app.openCmuxSettingsFile` (en/es), `menu.notifications.toggleUnread` (es), `menu.find.sendCtrlFToTerminal` (es), `menu.help.keyboardShortcutsSettings` (es) y las etiquetas `shortcut.*.label` reetiquetadas (caja/ventana). Las claves muertas (`menu.history.*`, navegador, `menu.app.makeDefaultTerminal`, `menu.window.taskManager`, `menu.preferences`, `contextMenu.moveWorkspaceToWindow`, …) se retiran.

## 16. Referencias

- Apple Human Interface Guidelines — The menu bar: https://developer.apple.com/design/human-interface-guidelines/the-menu-bar (orden Apple · App · File · Edit · Format · View · menús propios · Window · Help; \"prefer the default ordering\"; los menús específicos van entre View y Window).
- Apple HIG (histórica, mismo orden de ítems): https://leopard-adc.pepas.com/documentation/UserExperience/Conceptual/AppleHIGuidelines/XHIGMenus/XHIGMenus.html
- Modelo caja/ventana y persistencia: `docs/UNICONNECT.md`.

