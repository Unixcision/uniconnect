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

`~/Library/Application Support/cmux/`

- `session-com.cmuxterm.app.json` — snapshot de cmux (ya existía). UniConnect añade campos **opcionales**: `workspaces[].uniConnect` (`kind`, `credentialId`, `hostLabel`, `tmuxReady`) y `panels[].terminal.uniConnectTmuxSession`. Un snapshot antiguo sin estos campos se carga igual.
- `uniconnect/vault.uc` — comandos de conexión, AES-256-GCM con la clave maestra. Permisos 0600.
- `uniconnect/backup.uc` — último "Persistir ahora" (documento legible cifrado con la clave maestra). `uniconnect/history/` conserva las 30 últimas copias.
- `uniconnect/launchers/` — scripts zsh de un solo uso que arrancan cada ventana SSH (`rm -f "$0"` antes del `exec`). Se purgan a la hora.
- `uniconnect/.master-key` — clave maestra, 32 bytes aleatorios, modo 0600 (copia principal).

Clave maestra: la copia principal es el fichero 0600; además se **espeja** en el llavero de inicio de sesión (`kSecClassGenericPassword`, servicio `com.cmuxterm.app.uniconnect`, cuenta `master-key-v1`, `WhenUnlockedThisDeviceOnly`) sin permitir nunca diálogos interactivos. Motivo: la app va firmada ad-hoc (cada recompilación cambia de identidad) y el llavero clásico pediría la contraseña de la cuenta en cada instalación, o se colgaría si la pantalla está bloqueada. Las builds de desarrollo (bundle id distinto) usan `uniconnect-<sufijo>/` y no comparten bóveda con la app real.

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

1. Arranque → **Touch ID** (ventana de bloqueo a nivel `screenSaver` en todas las pantallas). cmux carga el snapshot por debajo; nada es visible hasta desbloquear.
2. Cajas locales: cmux recrea pestañas y splits. Si la pestaña tenía Claude, lanza `claude --resume <id> … --dangerously-skip-permissions` (el flag se añade siempre en `AgentResumeArgv.claudeResumeArgv`).
3. Cajas SSH: para cada pestaña con `uniConnectTmuxSession`, UniConnect genera un lanzador `ssh -t … '<tmux new-session -A -D -s ID>'` con el comando de la bóveda y lo pasa como comando inicial del terminal. `-A` engancha si existe, `-D` expulsa clientes muertos. No se reproduce scrollback local: lo aporta tmux.
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

## 8. Pendiente / limitaciones conocidas

- Estado por ventana (Connecting/Connected/Failed) y retry por ventana: hoy el estado se ve en el propio terminal (mensaje de ssh); reabrir la pestaña desde Cerradas vuelve a conectar.
- Reconexiones escalonadas: no implementadas; con muchas cajas SSH se abren en paralelo.
- Timeout de bloqueo por inactividad: pendiente.
- Grupos al importar: se crean con `createWorkspaceGroup`, que añade una caja ancla.
