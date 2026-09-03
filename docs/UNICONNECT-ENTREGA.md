# UniConnect — informe de entrega

Fecha: 2026-09-03 · Rama: `uniconnect` · Ruta: `~/Desktop/PROYECTOS/uniconnect` · Repo: https://github.com/Unixcision/uniconnect (upstream `manaflow-ai/cmux` conservado)

## 1. Resumen funcional

- **Cajas Local / SSH** al pulsar `+` (nombre, carpeta/comando de conexión, color). El tipo se persiste en el snapshot y se ve en la descripción de la caja (`Local · ~/ruta`, `SSH · user@host · tmux`).
- **Ventanas SSH = sesiones tmux con nombre** en el servidor (`ssh -t … 'tmux new-session -A -D -s <id>'`). ID sugerido `uc-<slug>-<4hex>`, validado y escapado. Página de bienvenida a pantalla completa en cajas SSH sin ventanas; comprobación de tmux con detección de SO/gestor/permisos e instalación previa confirmación.
- **Restauración**: tras cierre, crash o reinicio, cada ventana SSH reengancha a su tmux (scrollback y proceso intactos) y cada ventana local con Claude relanza `claude --resume <id> --dangerously-skip-permissions` (flag forzado; el wrapper inyecta `skipDangerousModePermissionPrompt`).
- **Cerrar ≠ matar**: cerrar una pestaña solo termina el cliente ssh; la sesión tmux sigue viva y la pestaña queda en **Cerradas** con su ID (reabrir / eliminar definitivamente con confirmación).
- **Persistencia**: autosave de cmux (8 s, atómico) + guardado tras desbloquear y tras cada cambio de UniConnect + **Persistir ahora** (⌘⌥S) con backup cifrado e historial de 30 copias.
- **Seguridad**: comandos de conexión solo en bóveda AES-256-GCM (clave maestra 0600 + espejo en llavero sin diálogos); snapshot e historial sin secretos; export/import en contenedor versionado con PBKDF2-SHA256 (600k) + AES-GCM, rechazo de ficheros manipulados/truncados, preview sin secretos y sin duplicados silenciosos; Touch ID al arrancar y **Bloquear** (⌘⌃L) con política explícita sin Touch ID (contraseña del sistema, avisada en pantalla).
- **Renombrado real**: producto/app/ejecutable `UniConnect` (`UniConnect DEV` en Debug), icono propio, textos y catálogos, scripts, CI, sdef e instalador. Bundle id propio `com.unixcision.uniconnect` (`.debug` en desarrollo), sesiones e historial en `Application Support/UniConnect/`, socket en `~/.local/state/uniconnect`: cmux y UniConnect conviven sin pisarse. Módulo Swift `cmux`/`cmux_DEV` y CLI `cmux` conservados a propósito (tests, hooks). Updater oficial capado. Carpeta y repo renombrados; `origin` actualizado; descripción y topics puestos con `gh`.

## 2. Commits (rama `uniconnect`, sobre `fix/sshpass-image-paste`)

| Commit | Contenido |
|---|---|
| `d6b5e0b` | Módulo UniConnect completo, campos de snapshot, intercepciones, menú, tests |
| `a0cc5f9` | Semilla por entorno, confirmación de instalación de tmux, política de clave maestra, README/docs/logo |
| `545bb2f` | Correcciones tras E2E real: lanzadores en `$TMPDIR`, `TERM`, mantener ventanas tmux abiertas, bóveda por bundle |
| `b2ea716` / `a1c98eb` | Plan y registro de validación |
| `e51175b` | Renombrado real del producto + icono + limpieza de READMEs de cmux |
| `371740b` | Pin de XcodeProj 9.12.0 (la ruta nueva re-resolvía a 9.16 y rompía la compilación) |
| `e0b…`/`5783aa8` | UniConnect desactivado bajo XCTest; informe de entrega |
| `da61c32` | Logo generado con Nano Banana Pro + icono; página SSH sin terminal detrás, legible en claro/oscuro; relleno Markdown sin PTY; assets de cmux retirados |
| `60bcf9f`…`bb79d98` | README con capturas reales sanitizadas (hero, selector, estado vacío SSH, bloqueo); Package.resolved |
| `6796a51` | Fechas de actividad, `· desconectada`, reconexión escalonada, "Terminar sesión tmux remota…", snapshot pre-import, bloqueo por inactividad, sharingType=none al bloquear, "Último guardado" |
| (este) | Sanitización de un fragmento de contraseña de ejemplo e IP en test/plan/informe |

Ficheros principales: `Sources/UniConnect/*`, `Sources/SessionPersistence.swift`, `Sources/Workspace.swift`, `Sources/TabManager.swift`, `Sources/WorkspaceContentView.swift`, `Sources/AppDelegate.swift`, `Sources/cmuxApp.swift`, `Packages/CMUXAgentLaunch/…/AgentResumeArgv.swift`, `Resources/bin/uniconnect-claude-wrapper`, `Resources/Info.plist`, catálogos `.xcstrings`, `cmux.xcodeproj/project.pbxproj`, `scripts/*`, `.github/workflows/*`, `cmuxTests/UniConnectTests.swift`, `README.md`, `docs/UNICONNECT.md`, `UNICONNECT_PLAN.md`.

## 3. Migraciones

- Snapshot de cmux: campos **opcionales** nuevos (`workspaces[].uniConnect`, `panels[].terminal.uniConnectTmuxSession`); snapshots antiguos cargan igual (test). No hay migración de bundle id porque no cambia.
- Secretos heredados: cmux no guardaba comandos ssh en claro (los lanzadores de resume viven en `$TMPDIR` y se autoborran); no hay nada que migrar.

## 4. Pruebas y comandos

- `xcodebuild test -scheme cmux-unit -only-testing:cmuxTests/UniConnectTests` → **25/25** (antes y después del renombrado).
- Suite completa `cmux-unit` (parcial, interrumpida por tiempo, pantalla bloqueada, DerivedData en ruta larga): 1650 OK / 122 fallos en clases de teclado-foco, WebKit, integración de notify y "Unix socket path is too long"; reejecución con DerivedData corto en `docs/UNICONNECT.md §9` (se actualiza al terminar).
- E2E real por socket con `scripts/cmux-debug-cli.sh` (ver registro en `docs/UNICONNECT.md §9`): semilla → tmux en servidor → `kill -9` → recuperación; ⌘Q → recuperación; cierre de pestaña sin matar tmux; Claude reanudado con `--resume` + flag.

## 4b. Logo

Generado el 2026-09-03 con **Nano Banana Pro** (`gemini-3-pro-image`, el modelo "premium" de imagen de la Gemini API; Nano Banana 2 `gemini-3.1-flash-image` es el más nuevo/rápido). Dos variantes, elegida la de chevrón + eslabón; post-proceso con ImageMagick (recorte 1024², esquinas redondeadas). La clave de API vive solo en el scratchpad de la sesión, no en el repo. Detalle y fuentes en `docs/UNICONNECT.md §10`.

## 5. Riesgos y limitaciones

- Firma ad-hoc: la clave maestra vive en fichero 0600 (llavero solo como espejo) para evitar diálogos y pérdida de bóveda entre recompilaciones. Con una firma de desarrollador estable se puede pasar al llavero de protección de datos.
- `sshpass` expone la contraseña en la lista de procesos durante la conexión (igual que a mano).
- `StrictHostKeyChecking=accept-new` acepta hosts nuevos sin preguntar (rechaza cambios de clave).
- Sin estado por ventana (Connecting/Failed) ni retry individual: la pestaña muestra el `[exited]` de Ghostty y se reabre desde Cerradas. Sin reconexión escalonada ni timeout de bloqueo por inactividad (roadmap).
- La primera vez que una build nueva accede a `~/Desktop` (claves en `~/.ssh/config`) o a la red local, macOS pide permiso; con la pantalla bloqueada ese diálogo no aparece y la app/`ssh` esperan.
- Textos de ayuda del CLI y `cmux.json` siguen diciendo `cmux` a propósito (el CLI no se renombra).

## 6. Configuración inicial (semilla)

Fichero `~/Desktop/PROYECTOS/uniconnect-seed.json` (fuera del repo, permisos 0600, contiene una contraseña de sshpass). Tres cajas, tal como las pidió Dani el 03/09:

- **GESTIONES SISTEMA MAC** (Local, `~`, azul): 10 ventanas, cada una `claude --resume <id> --dangerously-skip-permissions` con nombre visible (PANENKA BETS, RANDOM STUFF, CASTLE ROCKET, MISC VARIADO, 30 PAVOS DAVINCI, COMPARA RENFE, BETFAIR/WH CHATS, GYM DATOS, PORN VIDEOS, CREADOR PLANOS). Nota: RANDOM STUFF y BETFAIR/WH CHATS llevan el mismo id de sesión en la lista recibida.
- **NOTBETTING** (SSH, rojo): clave `.pem` de prepro; seis ventanas enganchadas a los tmux existentes `claudefixerrors`, `claudefixerrors_2`, `claudefixerrors_3-7`, `claudesupport`, `claudesupportliga`, `miamigoclaude` (no se crean sesiones nuevas: `tmux new-session -A` engancha a las existentes).
- **COMECAMPUS** (SSH, verde): `sshpass` + `StrictHostKeyChecking=no` tal como se dio; una ventana `shell` con sesión tmux nueva `comecampus`. Validado en la build de pruebas: importación por semilla → sesión `comecampus` creada y enganchada en el servidor.

Cómo importarla en la app instalada: **UniConnect ▸ Importar configuración…** (Touch ID → preview → Importar) o una sola vez con `UNICONNECT_IMPORT_SEED=~/Desktop/PROYECTOS/uniconnect-seed.json` al lanzar. Al enganchar NOTBETTING, `-D` expulsa a los clientes de cmux que estuvieran en esos tmux (deseado al migrar). Para añadir cajas después: editar el JSON y reimportar (las existentes por nombre vienen desmarcadas).

## 6b. Evidencias adicionales (03/09, pantalla desbloqueada)

- **Persistir ahora** por menú: `backup.uc` + copia en `history/`, descifrado con la clave maestra y verificado (cajas, ventanas, tmux, connect).
- **Cerradas**: pestaña `e2e-b` cerrada por socket y reabierta desde el menú History → reenganchada a `uc-e2e-b` (`attached=1`), ID conservado.
- **Bloquear**: ventana de bloqueo a nivel 1000 sobre toda la pantalla; ventanas principales con `sharingType=none` (verificado con CGWindowList); captura en el README.
- Tests: 27/27.

## 7. Pendiente de autorización / de pantalla desbloqueada

- Push hecho a `origin/uniconnect` (autorizado por THE_BIG_GOAL §2); rama por defecto del repo `uniconnect`. Sin PR ni release.
- **Aviso de seguridad**: un test contenía un fragmento de una contraseña de ejemplo pegada en el chat y la IP de ese host; se ha sustituido en el último commit, pero sigue en el historial ya subido. Recomendación: rotar esa contraseña (o autorizar reescribir la rama).
- Con huella real (no automatizable): desbloqueo Touch ID al arrancar y tras Bloquear, exportar e importar desde el menú (la lógica de cifrado, manipulación y contraseña incorrecta está cubierta por tests).
- Instalación en `/Applications` con `~/Desktop/PROYECTOS/uniconnect-install-patched.sh` (compila Release, hace backup de la app actual, capa updates). No ejecutado todavía para no cerrar el cmux que estás usando.
