# UniConnect — documentación técnica (ES)

UniConnect es cmux con una capa de **persistencia de sesiones** pensada para sobrevivir a cierres, crashes y reinicios, y con **secretos cifrados** y **Touch ID**. El README (inglés) es la puerta de entrada; este documento describe formato, restauración, seguridad y límites con detalle.

## 1. Modelo

| Concepto | Qué es | Dónde vive |
|---|---|---|
| Caja (workspace) | Local (carpeta del Mac) o SSH (servidor) | `Workspace.uniConnectProfile` → snapshot `uniConnect` |
| Ventana (tab) local | Terminal normal; si corre Claude Code, cmux guarda su session id vía hooks | snapshot `terminal.agent` / `resumeBinding` |
| Ventana (tab) SSH | Cliente ssh enganchado a **una sesión tmux con nombre** en el servidor | snapshot `terminal.uniConnectTmuxSession` |
| Comando de conexión | `ssh …`, `sshpass -p … ssh …`, `-i`, `-p`, `-J`… | **Bóveda cifrada** (`vault.uc`), referenciado por `credentialId` |

Reglas de ID tmux: letras, dígitos, `-` y `_`, máximo 40 caracteres, sin `.` ni `:` (tmux los prohíbe). Todo lo demás se sustituye por `-`. Sugerencia automática: `uc-<slug>-<4 hex>`.

## 2. Ficheros en disco

`~/Library/Application Support/UniConnect/` (identidad propia: bundle `com.unixcision.uniconnect`, socket en `~/.local/state/uniconnect`; cmux conserva su carpeta y su historial intactos)

- `session-com.unixcision.uniconnect-uniconnect.json` — snapshot con el formato de cmux. UniConnect añade campos **opcionales**: `workspaces[].uniConnect` (`kind`, `credentialId`, `hostLabel`, `tmuxReady`) y `panels[].terminal.uniConnectTmuxSession`. Un snapshot antiguo sin estos campos se carga igual.
- `vault.uc` — comandos de conexión, AES-256-GCM con la clave maestra. Permisos 0600.
- `backup.uc` — último "Persistir ahora" (documento legible cifrado con la clave maestra). `history/` conserva las 30 últimas copias.
- `$TMPDIR/uniconnect-launchers/` — scripts zsh de un solo uso (0700) que arrancan cada ventana SSH (`rm -f "$0"` antes del `exec`); se purgan a la hora. Viven en `$TMPDIR` porque Ghostty parte el comando por espacios y `Application Support` lleva uno. Mientras existen contienen el comando de conexión completo, igual que los lanzadores de resume de cmux.
- `.master-key` — clave maestra, 32 bytes aleatorios, modo 0600 (copia principal).

Clave maestra: la copia principal es el fichero 0600; además se **espeja** en el llavero de inicio de sesión (`kSecClassGenericPassword`, servicio `com.unixcision.uniconnect.master-key`, cuenta `master-key-v1`, `WhenUnlockedThisDeviceOnly`) sin permitir nunca diálogos interactivos. Motivo: la app va firmada ad-hoc (cada recompilación cambia de identidad) y el llavero clásico pediría la contraseña de la cuenta en cada instalación, o se colgaría si la pantalla está bloqueada. Las builds de desarrollo (bundle id distinto) usan `UniConnect-<sufijo>/` y no comparten bóveda con la app real. La primera vez que arranca la app con identidad propia mueve fichero a fichero lo que hubiera en la ubicación antigua (`cmux/uniconnect/`) y copia una sola vez los ajustes (UserDefaults) de cmux.

## 3. Documento legible (lo que se exporta / importa)

```json
{
  "app": "UniConnect", "version": 1, "savedAt": "2026-09-02T21:00:00Z",
  "workspaces": [
    { "name": "NOTBETTING", "kind": "local", "color": "#1565C0", "cwd": "~/Desktop/NOTBETTING",
      "windows": [ { "name": "claude", "claudeSession": "bd3a3ea6-…" } ] },
    { "name": "VPS", "kind": "ssh", "color": "#C0392B",
      "connect": "sshpass -p '…' ssh root@1.2.3.4",
      "windows": [ { "name": "claude", "tmux": "uc-claude-1a2b" }, { "name": "logs", "tmux": "uc-logs-9f01" } ] }
  ]
}
```

`connect` es el único campo sensible; por eso el documento **nunca** se escribe en claro. La semilla inicial (plantilla) sí es JSON plano porque la escribe el usuario a mano y se importa una vez.

## 4. Contenedor de exportación

```json
{ "format": "uniconnect-export", "version": 1,
  "meta": { "app": "UniConnect", "savedAt": "…", "workspaces": 12, "hostName": "MacBook" },
  "payload": { "format": "uniconnect-aesgcm", "version": 1, "kdf": "pbkdf2-sha256", "iterations": 600000,
               "salt": "<b64 16B>", "nonce": "<b64 12B>", "ciphertext": "<b64>", "tag": "<b64 16B>" } }
```

- Cifrado: AES-256-GCM (CryptoKit). AAD = nombre del formato. Nonce y salt aleatorios por cifrado.
- KDF: PBKDF2-HMAC-SHA256, 600 000 iteraciones (CommonCrypto). Parámetros en cabecera; la frase nunca se guarda.
- Cualquier byte alterado en `ciphertext`/`tag`/`nonce` hace fallar la autenticación GCM → "Contraseña incorrecta o fichero manipulado" (el mensaje no distingue a propósito).
- Un fichero truncado o con formato distinto se rechaza antes de pedir la contraseña.

## 5. Restauración

1. Arranque → **Touch ID** (ventana de bloqueo a nivel `floating` en todas las pantallas: tapa la app pero no el diálogo de Touch ID del sistema). cmux carga el snapshot por debajo; nada es visible hasta desbloquear.
2. Cajas locales: cmux recrea pestañas y splits. Si la pestaña tenía Claude, lanza `claude --resume <id> … --dangerously-skip-permissions` (el flag se añade siempre en `AgentResumeArgv.claudeResumeArgv`).
3. Cajas SSH: para cada pestaña con `uniConnectTmuxSession`, UniConnect genera un lanzador (que exporta `TERM=xterm-256color`, porque el `xterm-ghostty` de Ghostty no suele existir en los servidores y tmux se niega a engancharse) `ssh -t … '<tmux new-session -A -D -s ID>'` con el comando de la bóveda y lo pasa como comando inicial del terminal. `-A` engancha si existe, `-D` expulsa clientes muertos. No se reproduce scrollback local: lo aporta tmux.
4. Tras desbloquear se fuerza un autosave.

Cerrar una pestaña SSH solo mata el cliente `ssh`; tmux se desengancha y sigue vivo. La pestaña va a **Cerradas** (ClosedItemHistory de cmux, con el ID tmux dentro del snapshot) y se reabre con el mismo ID.

## 6. Modelo de amenaza y límites

Protege contra: lectura del disco (snapshots, backups, exports) sin la sesión de usuario desbloqueada o sin la frase de exportación; manipulación de exports; apertura de la app por alguien con acceso físico sin la huella.

**No** protege contra: un proceso malicioso corriendo con tu usuario (puede leer `.master-key`, que va protegido solo por permisos 0600, FileVault y la sesión de usuario; con una firma de desarrollador estable se podría pasar la copia principal al llavero de protección de datos); un atacante con root; captura de pantalla mientras la app está desbloqueada; un servidor SSH comprometido. `sshpass` expone la contraseña en la lista de procesos del Mac durante la conexión, igual que cuando lo tecleas a mano. `StrictHostKeyChecking=accept-new` acepta hosts nuevos automáticamente (evita el prompt interactivo) pero rechaza cambios de clave.

Política de autenticación: Touch ID si hay sensor; si no hay biometría, no está configurada o está bloqueada por intentos, se pide la **contraseña de la cuenta** con el mismo diálogo del sistema y se avisa en pantalla. No hay bypass silencioso. Para pruebas automatizadas: `UNICONNECT_DISABLE_LOCK=1` en el entorno (nunca en producción).

## 7. Variables de entorno

| Variable | Efecto |
|---|---|
| `UNICONNECT_DISABLE_LOCK=1` | Sin Touch ID (solo tests/automatización) |
| `UNICONNECT_DISABLE=1` | Desactiva el selector Local/SSH y el resto de intercepciones (comportamiento cmux puro) |
| `UNICONNECT_IMPORT_SEED=<ruta>` | Importa una semilla JSON (o un export cifrado si hay `UNICONNECT_TEST_PASSPHRASE`) una sola vez tras desbloquear. Sin variable, se usa `~/Library/Application Support/UniConnect/seed.json` si existe (aprovisionamiento del primer arranque) |
| `UNICONNECT_TEST_PASSPHRASE`, `UNICONNECT_TEST_EXPORT_PATH` | Ganchos de automatización para exportar/importar sin diálogos; **solo se honran si el bloqueo está desactivado** (`UNICONNECT_DISABLE_LOCK=1`), nunca en uso normal |

## 8. Pendiente / limitaciones conocidas

- Estado por ventana: cuando el cliente ssh muere, la pestaña se conserva con el `[exited]` de Ghostty y su título pasa a `nombre · desconectada`; la reconexión es reabrir la pestaña (Cerradas) o crear una ventana con el mismo ID tmux. No hay un botón "Reconectar" dentro de la pestaña.
- Reconexión escalonada: los lanzadores generados en la misma ráfaga (≤5 s) esperan 0, 0.4, 0.8… s (máx. 6 s) antes de conectar.
- Bloqueo automático por inactividad: menú **UniConnect ▸ Bloqueo automático por inactividad** (5/15/30/60 min, desactivado por defecto); usa la inactividad global del sistema. Al bloquear, las ventanas pasan a `sharingType = .none` (no aparecen en grabaciones ni capturas) hasta desbloquear.
- **Terminar sesión tmux remota de la ventana activa…**: única acción que ejecuta `tmux kill-session`, siempre con confirmación explícita; cerrar una pestaña nunca lo hace.
- Antes de importar se fuerza un snapshot completo y un backup cifrado (`history/`) para poder deshacer.
- Grupos al importar: se crean con `createWorkspaceGroup`, que añade una caja ancla.
- Firma ad-hoc: ver §2/§6 sobre la clave maestra.

## 9. Registro de validación (build real, 2026-09-02/03)

Build Debug etiquetada (`UniConnect DEV uniconnect.app`, bundle `com.unixcision.uniconnect.debug.uniconnect`), pantalla del Mac bloqueada durante toda la prueba, control por socket con `scripts/cmux-debug-cli.sh`.

| Paso | Resultado |
|---|---|
| Semilla `UNICONNECT_IMPORT_SEED` (caja local `~` con 2 ventanas + caja SSH con 2 ventanas tmux) | Cajas creadas con nombre, color y descripción `Local · ~` / `SSH · root@… · tmux`; snapshot sin `sshpass` ni rutas `.pem` |
| Ventanas SSH | `tmux ls` en el servidor muestra `uc-e2e-a` y `uc-e2e-b` con cliente enganchado; la pantalla muestra la barra de tmux |
| Proceso dentro de cada tmux (`sleep 900`) + `kill -9` de la app | Sesiones vivas y desenganchadas (`attached=0`), `sleep` intacto |
| Relanzar | Cajas, nombres, colores, IDs tmux restaurados; `attached=1`; scrollback con los marcadores `UC-MARK-*` visible |
| Cerrar una pestaña SSH por socket | `uc-e2e-b` sigue viva (`attached=0`); el historial de Cerradas guarda la pestaña con `uniConnectTmuxSession=uc-e2e-b` y sin secretos |
| ⌘Q (AppleEvent quit) + relanzar | Cierre limpio en 1 s; tmux vivos; solo la pestaña abierta se restaura |
| Claude Code en la caja local (`claude --dangerously-skip-permissions`, un prompt) | Hook registra el session id; snapshot: `agent=05a0da08`, `wasAgentRunning=true`, política `auto` |
| ⌘Q + relanzar | La app lanza sola `claude --resume 05a0da08-… --dangerously-skip-permissions` |
| Tests | `UniConnectTests`: 25/25 (cripto, manipulación, IDs tmux, inyección de opciones ssh, contenedor de export, snapshot legado, lanzador) |
| Renombrado real | `UniConnect DEV uniconnect.app` con `Contents/MacOS/UniConnect DEV`, `bin/cmux` presente; misma restauración; tests 25/25 |

Verificado después con pantalla desbloqueada: página de bienvenida SSH (sin consola detrás), reapertura desde **Cerradas** (History) con reenganche tmux, **Persistir ahora** (backup descifrado y comprobado), **Bloquear** (ventana de bloqueo + `sharingType=none`), exportación real (contenedor descifrado con la contraseña) e importación (manipulado y contraseña incorrecta rechazados; válido importa sin duplicar). El flujo de bloqueo/desbloqueo se prueba además con un autenticador inyectado (`UniConnectAuthenticating`): éxito, fallo, biometría bloqueada y acción sensible. La única comprobación que queda fuera de la automatización es física: poner el dedo en el sensor.

## 10. Logo e icono

El logo (`docs/assets/logo.png`, y de él todas las tallas de `Assets.xcassets/AppIcon.appiconset` y la capa de `AppIcon.icon`) se generó el 2026-09-03 con **Nano Banana Pro** (`gemini-3-pro-image`, Gemini API, endpoint `models/gemini-3-pro-image:generateContent` con `responseModalities: ["IMAGE"]`), el modelo que Google describe como su opción premium para precisión de marca; Nano Banana 2 (`gemini-3.1-flash-image`) es el lanzamiento más reciente y más rápido. Prompt: chevrón de terminal entrelazado con un eslabón (conexión persistente), estilo icono de app de Apple, fondo oscuro, gradientes coral y cian, sin texto. Post-proceso con ImageMagick: recorte, 1024×1024 y esquinas redondeadas transparentes. Fuentes: https://ai.google.dev/gemini-api/docs/image-generation · https://blog.google/innovation-and-ai/technology/ai/nano-banana-2/ . La clave de API no está en el repo.
