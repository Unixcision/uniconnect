# UniConnect — Linux desktop

The Linux desktop lives in this checkout alongside the original macOS sources.
It uses native GTK 3/VTE terminals, OpenSSH and tmux, with encrypted connection
storage and the original workspace import/export envelope. Development status and
remaining differences are recorded in [PORT_STATUS.md](PORT_STATUS.md).
This is the Linux edition of the same UniConnect product, not a separate fork.
Both platforms follow the [shared development policy](../docs/CROSS-PLATFORM.md).

El adaptador móvil personal y sus límites están documentados en
[Acceso móvil por Tailscale](MOBILE_ACCESS.md). No implica paridad visual completa
con macOS ni validación de Android en Linux.

Favoritos, orden de cajas/ventanas y sincronización con los clientes del host:
[guía de favoritos y orden](../docs/LINUX-FAVORITOS.md).

## Install and open

On Ubuntu 24.04:

```bash
bash linux/install.sh --dependencies
~/.local/bin/uniconnect
```

The installer adds UniConnect to the desktop application menu and installs a
launcher pointing to this checkout. Keep the checkout in place. Existing launchers
are backed up before replacement. `uniconnect-cli` controls this app; the `cmux`
alias is installed only when it is not already present.

## Workspaces and recovery

The sidebar lists Local/SSH boxes. Each box contains named terminal windows, and
windows can be divided into panels. Closing a window puts it in Closed; closing
the application detaches its clients while tmux retains the running processes.
Reconnection checks and attaches to the exact saved tmux. It never creates an
empty replacement for a missing session.

Import accepts UniConnect seeds, macOS snapshots, encrypted `.uniconnect` exports
and the `iberiavo-workspaces/v1` map. An SSH command can be supplied for a map that
contains session IDs but no connection. Repo metadata and the original resume
working directory are kept separately. Provider IDs keep their original agent:
Codex, Claude and Antigravity histories are not interchangeable.

GUI imports and SSH endpoint edits keep existing clients alive while provisional
clients attach to every exact saved tmux target. The new configuration is committed
only after client-correlated attachment proof; cancel, timeout or failed persistence
discards the provisional clients and restores the original state/vault pair.
This path does not create missing sessions or run direct agent commands from an
import. Legacy local windows without an existing tmux target cannot be activated
through this transactional import path. Automatic startup remains password-free.

An explicit first import can be launched with:

```bash
~/.local/bin/uniconnect --import-file /path/to/workspaces.json \
  --connect 'ssh -i /path/to/key.pem user@host' --locale es
```

For recovery across server reboots, see [the remote recovery guide](scripts/README.md).
The supervisor waits for an existing native writer lock to be released before
resuming the same UUID. It preserves user processes already running elsewhere.
Stopping or restarting the supervisor does not stop tmux.

## Storage and encryption

State lives in `$XDG_STATE_HOME/uniconnect` (normally
`~/.local/state/uniconnect`). `state.json` contains workspaces and credential IDs;
SSH commands are only stored in `vault.uc` using AES-256-GCM. Files are private,
written with fsync and atomic replacement. Closed items retain stable IDs.

On this root-owned Linux installation, automatic opening uses `systemd-creds` host
encryption. `master-key.systemd.ctl.enc` contains an encrypted UniConnect key;
the host key is managed by systemd at `/var/lib/systemd/credential.secret`.
No application startup password or login screen is required. This is deliberate
user configuration. The encrypted key is tied to this host; portable backups use
the separate passphrase-protected export format. Desktop Secret Service and an
explicit passphrase backend remain available for other installations.

Recovery snapshots pair readable JSON with an encrypted credential companion,
every six hours, retaining seven days and at most 28 scheduled points. Manual save
also creates a checkpoint. Imports and restores checkpoint the current state.

## Shortcuts and local control

### Copiar texto arrastrando en tmux

En Linux, los nuevos lanzamientos, recuperaciones y relanzados gestionados de
Codex usan `--no-alt-screen` para dejar el texto en el historial del terminal.
La pantalla alternativa puede tener su propio scroll interno mientras tmux
indica «0 de 0»; cambiar el color de selección no crea ese historial.
Las instancias ya abiertas necesitan un relanzado con la misma conversación
para adoptar la opción. Si Codex tiene trabajo en curso, el plan de relanzado
lo avisa: **Aplicar** autoriza interrumpirlo y reabrir la misma conversación.
El cierre sigue bloqueado cuando hay un borrador o un diálogo sin reconocer.

En una terminal local o SSH con tmux, mantén **Mayús** y arrastra con el botón
izquierdo para seleccionar el historial, incluso por encima del borde superior
visible. Mantén pulsado ahí para que la vista avance mientras amplía la
selección; al soltarla, usa **clic derecho → Copiar** o **Ctrl+Mayús+C**. **Esc**
cancela el modo de selección; **Ctrl+C** sigue enviándose al programa y no se
convierte en Copiar. Sin Mayús, la selección sigue el comportamiento y los
bindings de tmux. UniConnect cambia a azul el estilo naranja predeterminado y
conserva los colores y bindings personalizados.

La selección larga depende del historial de tmux. Los lanzamientos gestionados
de Codex usan `--no-alt-screen` para que su salida permanezca en ese historial;
las sesiones existentes necesitan un relanzado conservando la misma conversación.
El relanzado avisa si detecta trabajo en curso y bloquea estados no reconocidos.
Al reconectar o adjuntarse a un servidor existente, UniConnect no cambia sus
bindings ni opciones globales; solo migra el color naranja predeterminado. Copiar
desde UniConnect se publica también al portapapeles X11 que x11vnc reenvía al
espectador. La prueba automatizada cubre el mensaje RFB clásico con x11vnc. Pegar
desde el espectador también depende de que el servidor VNC concreto entregue su
texto entrante al portapapeles GTK; conviene comprobarlo en el equipo de destino.
Estas opciones pertenecen al adaptador Linux y no cambian macOS.

### Relanzar Codex

**Relanzar IA** permite elegir la ventana actual, todas las ventanas de su
espacio de trabajo o las del equipo. El plan enumera los objetivos y avisa si
Codex está trabajando o tiene terminales de fondo. **Aplicar** autoriza
interrumpir ese trabajo, cerrar Codex con `/exit` y reanudar su conversación en
el mismo panel y carpeta; la conversación y los archivos ya guardados se
conservan. Un borrador, un diálogo no reconocido o un cambio de identidad o
configuración bloquea el cierre. **Reconectar** solo vuelve a conectar el
terminal a tmux; no reinicia la IA.

The Linux terminal uses Ctrl+Shift combinations so Ctrl+C remains available to
shell programs. Settings exposes editable shortcuts, font, appearance
and optional idle locking. Defaults include:

| Action | Linux shortcut |
| --- | --- |
| New box / window | Ctrl+Shift+N / Ctrl+Shift+T |
| Close / reopen window | Ctrl+Shift+W / Ctrl+Alt+T |
| Copy / paste / find | Ctrl+Shift+C / Ctrl+Shift+V / Ctrl+Shift+F |
| Reconnect / reconnect all | Ctrl+Shift+R / Ctrl+Alt+R |
| Split right / down | Ctrl+Shift+D / Ctrl+Alt+D |
| Save / command palette | Ctrl+Shift+S / Ctrl+Shift+P |
| Previous / next workspace | Ctrl+Alt+[ / Ctrl+Alt+] |
| Previous / next window | Ctrl+Shift+[ / Ctrl+Shift+] |
| Workspace / window by number | Ctrl+Alt+1…9 / Alt+1…9 (9 selects last) |
| Maximize / restore pane | Ctrl+Shift+Enter |
| Focus adjacent pane | Ctrl+Alt+arrow |
| Find next / previous | Ctrl+Shift+G / Ctrl+Alt+G |
| Reopen last closed | Ctrl+Shift+Alt+T |

The private mode-0600 Unix socket also checks the peer's user ID. Read-only CLI
examples:

```bash
uniconnect-cli list-workspaces
uniconnect-cli --workspace workspace:1 list-surfaces
uniconnect-cli identify
```

`select-workspace`, `focus-surface`, `send`, `send-key`, `read-screen`, `reconnect`,
`close-surface` and `persist` use the same live UI state. This is a subset of the
original cmux command surface, not a claim of full socket API equivalence.

## Validation

The Linux port is verified with isolated state directories, sacrificial tmux
sockets and real GTK/VTE in Xvfb. These do not reuse live user sessions as test
fixtures:

```bash
xvfb-run -a linux/.venv/bin/python -m unittest discover -s linux/tests -v
```

The tests cover authenticated encryption, import identity, state and backup
recovery, SSH parsing, actual tmux ownership and reconnect lifecycle, and actual
SFTP byte transfer/cancellation. Exact current results belong in PORT_STATUS.md.

The Linux interface is Spanish-only and reads the same Spanish catalogue as macOS.
Older imported language preferences are accepted but do not change the interface.
`--locale` accepts only `es`; Settings no longer offers a language selector. Stable
shared keys resolve labels without depending on an English translation dictionary.

## Identidad de conversaciones Claude/Codex

Al crear un pane gestionado de Claude o Codex, UniConnect añade un hook limitado
a ese lanzamiento. Obtiene `session_id` de `SessionStart` en Claude y `thread-id`
de `agent-turn-complete` en Codex. Son identificadores emitidos por el agente,
no UUID de conversación inventados ni búsquedas de la conversación más reciente.
El ID y el historial se guardan juntos, conservando las entradas importadas y la
conversación anterior cuando cambia el ID. La consulta de metadatos usa el ciclo
de guardado (8 segundos), agrupada por conexión/socket, no por tecla o byte.

La señal se vincula al pane tmux, ventana, PID/generación del proceso y nonce de
lanzamiento. Un hook tardío o de otro pane no puede sustituir esa identidad. No
se guardan prompts, respuestas ni rutas de transcripciones. Un ID conservado
después de salir del agente es histórico: **no demuestra que la IA siga activa
ni autoriza enviarle texto como chat**.

Hasta recibir la señal se muestra «ID nativo pendiente de la señal del agente».
En Codex esto puede durar hasta finalizar el primer turno; también ocurre si el
hook está desactivado, falta Python o el proceso ya estaba abierto sin esta
integración. No se reinicia ni se mata ese proceso para conseguir un ID.
Si falla la preparación del hook, se ejecuta el agente original sin cambiar sus
argumentos. No se instalan archivos ni se reescriben configuraciones globales.
La opción `notify` de Codex es por invocación y prevalece sobre un `notify`
configurado previamente para ese lanzamiento; no se encadenan comandos ajenos
leyendo configuración o argumentos capturados. Los comandos personalizados no
se interceptan. macOS mantiene su bridge nativo existente; este es el adaptador
de identidad del transporte Linux, no una segunda base de conversaciones.

Contratos oficiales: [hooks de Claude](https://code.claude.com/docs/en/hooks),
[opción `--settings` de Claude](https://code.claude.com/docs/en/cli-reference) y
[notificaciones de Codex](https://learn.chatgpt.com/docs/config-file/config-advanced).
