# Contrato `accounts.v1`: «Cuentas de IA»

Una vista grande y limpia de **con qué cuenta está cada IA**: Claude, Codex y las demás. Se puede
ver por espacio de trabajo, por ventana o por cuenta, y filtrar por cuenta (por ejemplo,
`dev@notbetting.com`) para ver todas las ventanas que la usan.

Lo pidió Dani el 10-11-2026: «que esté actualizado y fresco: si en un VPS cambio la cuenta en una
ventana con login, que no tome datos cacheados como reales».

Estos ficheros **son el contrato**. Si un ejemplo y una implementación discrepan, manda el ejemplo.

| Archivo | Qué fija |
|---|---|
| `sonda-cuentas.json` | Casos de `account_of` (la cuenta de UNA IA): entorno del proceso + ficheros → `account`. Los pasa `linux/tests/test_agent_probe_accounts.py`. |
| `accounts-request.json` | Parámetros de `mobile.accounts.list`. |
| `accounts-response.json` | Respuesta completa de ejemplo: hosts y ventanas en todos los estados. |
| `paleta.json` | Color de cada cuenta: la misma cuenta, el mismo color en Mac, Linux y Android. |
| `errors.json` | Errores de la llamada, cuándo salen y su mensaje. |

## 1. Frescura: la regla que manda

- **Cada lectura va a la fuente en ese momento.** Nada de cachés entre llamadas: ni en la sonda,
  ni en el escritorio, ni en el móvil.
  - La sonda abre `.claude.json` y `auth.json` cada vez. Solo recuerda un fichero durante una
    misma ejecución, para no leerlo 30 veces si 30 ventanas comparten usuario.
  - El escritorio lanza las sondas cada vez que alguien pide la lista.
  - Android pide la lista al abrir la pantalla, al tirar para refrescar y cada 15 s mientras
    está visible.
- **Si un host no contesta, sus ventanas salen `host_inaccesible`, sin cuenta.** Nunca con la
  última cuenta conocida: una cuenta vieja pintada como actual es justo lo que hay que evitar.
- La ventana del escritorio refresca al abrirse, cada **15 s** mientras está visible y con el
  botón «Actualizar». Enseña «Leído en vivo hace N s» con el `checked_at` de la respuesta.
- Si llega una petición con otra lectura en curso, se espera a esa lectura y se comparte su
  resultado. No se encolan dos.

## 2. La sonda: `agent_probe.py --accounts`

Se usa la sonda compartida del árbol IA (`linux/uniconnect/agent_probe.py`, contrato
`agent-tree-v1`) con un interruptor nuevo:

- Con `--accounts`, cada `agent` no nulo lleva además `account`.
- Sin él, la salida es idéntica a la de antes, así que los lectores actuales no cambian.
- `version` sigue siendo 1, porque es una clave añadida.

Mac y Linux la ejecutan igual:
- **En local:** `python3 agent_probe.py --socket <socket> --accounts --session <s>...`. En el Mac,
  con `/usr/bin/python3` y el socket `uniconnect-local`.
- **En SSH:** `python3 - --socket default --accounts --session <s>...`, con el script por stdin,
  por el canal de la caja y con un plazo de 10 s. Una conexión por host, nunca una por ventana.

```json
"account": {
  "state": "ok" | "sin_sesion" | "no_legible" | "desconocida",
  "email": "dev@notbetting.com" | null,
  "method": "oauth" | "chatgpt" | "api_key" | "bedrock" | "vertex" | "foundry" | null,
  "plan": "Ultra" | "Max" | "Pro" | ... | null,
  "organization": "..." | null,
  "os_user": "root" | null,
  "config": "/root/.claude.json" | null,
  "read_at": "2026-11-10T12:30:04Z"
}
```

### De dónde sale la cuenta (y nada más)

**Entorno del proceso.** Linux lo lee de `/proc/<pid>/environ`. macOS, con sysctl
`KERN_PROCARGS2`, que solo funciona con procesos del mismo usuario. Solo se miran:
- `HOME`, `CLAUDE_CONFIG_DIR` y `CODEX_HOME`: rutas absolutas;
- `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `OPENAI_API_KEY` y `CLAUDE_CODE_USE_*`: solo si
  están puestas. **El valor de un secreto no sale nunca de la sonda.**

Si el entorno no se puede leer, vale el HOME del usuario dueño del proceso.

**Claude** (`provider: claude`):
1. Con `CLAUDE_CODE_USE_BEDROCK`, `_VERTEX` o `_FOUNDRY` activo: `ok`, `method` con ese
   proveedor y sin email.
2. Fichero: `$CLAUDE_CONFIG_DIR/.claude.json` si existe la variable; si no, `$HOME/.claude.json`.
   - Sin permiso de lectura: `no_legible`.
3. Con `oauthAccount.emailAddress`: `ok`, `method: oauth` y `email` en minúsculas.
   - `organization` = `oauthAccount.organizationName`.
   - `plan` = `planDisplayName`. Si no está, `claudeAiOauth.subscriptionType` de
     `.credentials.json` (en `$CLAUDE_CONFIG_DIR` o en `~/.claude`), con mayúscula inicial. Si
     tampoco, se traduce `organizationType`: `claude_max` → `Max`, `claude_pro` → `Pro`, y así.
   - De `.credentials.json` **solo** se lee `subscriptionType`. Los tokens no se tocan.
4. Si no hay `oauthAccount` pero sí `ANTHROPIC_API_KEY` o `ANTHROPIC_AUTH_TOKEN`: `ok`,
   `method: api_key` y sin email.
5. Si no hay nada de eso: `sin_sesion`.

**Codex** (`provider: codex`):
- Fichero: `$CODEX_HOME/auth.json`, o `$HOME/.codex/auth.json`.
- Del `tokens.id_token` (un JWT que se decodifica sin verificar) salen `email` y
  `https://api.openai.com/auth.chatgpt_plan_type`, este último con mayúscula inicial. Con email:
  `ok` y `method: chatgpt`.
- Si no hay email pero sí `OPENAI_API_KEY`, en el fichero o en el entorno: `ok` y `api_key`.
- Si no hay nada: `sin_sesion`. Sin permiso de lectura: `no_legible`.

**agy, grok y cualquier otro:** `desconocida`, porque UniConnect no sabe dónde guardan la cuenta.
Se pinta «Cuenta no expuesta». No se adivina.

**Nunca sudo.** Si la IA corre como otro usuario y la sonda no puede leer sus ficheros, el
resultado es `no_legible`, con `os_user` diciendo quién es. Es el caso de una caja que entra como
`dgomezm` con una IA de root.

**Varias ventanas comparten cuenta** cuando corren con el mismo usuario y la misma carpeta de
configuración. Si haces `/login` en una, todas las de esa carpeta pasan a la cuenta nueva, y la
vista lo enseña así: `config` dice qué fichero se leyó.

## 3. La llamada: `mobile.accounts.list`

- Método `mobile.accounts.list`; en el socket de escritorio, `accounts.list`. El JSON es el mismo
  en los tres sitios.
- Capacidad: `accounts.v1`.
  - El Mac la anuncia en `mobile.workspace.list` (`capabilities`).
  - Linux la anuncia en `mobile.host.status` y en `mobile.workspace.list`.
  - Sin ella, Android no enseña la entrada.
- Parámetros (`accounts-request.json`): todos opcionales. `workspace_id` restringe la lista a un
  espacio de trabajo. Sin parámetros, devuelve todas las ventanas de todos los espacios.
- Es **solo lectura**: no persiste nada, no escribe en ningún panel y no lanza nada.
- Tarda como mucho **12 s**, con todas las sondas en paralelo y 10 s cada una.
- Si la app está bloqueada: error `locked`.

### Respuesta (`accounts-response.json`)

Todas las claves están siempre; las que no aplican van `null`. Las fechas van en ISO 8601 UTC (`Z`).

- `version`: 1. `checked_at`: cuándo se terminó la respuesta.
- `hosts`: un elemento por host leído.
  - `host_key`: `local`, o `ssh:<user>@<hostname>:<port>`, del destino efectivo, como en los
    Detalles.
  - `label`: «Este Mac» o «Este equipo» en local; en SSH, `<user>@<hostname>:<port>`.
  - `kind`: `local` o `ssh`.
  - `state`: `ok`, `host_inaccesible` (no contestó, venció el plazo o falta python3) o
    `boveda_cerrada` (sin credencial con la que conectar).
  - `checked_at`: la lectura de ese host.
- `windows`: un elemento por ventana, en el orden de la barra lateral (espacio y luego ventana).
  - `workspace_id`, `workspace` (nombre visible), `terminal_id`, `window` (nombre visible) y
    `host_key`.
  - `tmux_session`: o `null` si la ventana no tiene tmux.
  - `state`, la primera regla que se cumpla:
    1. `host_inaccesible`, si el host no se pudo leer (incluida la bóveda cerrada);
    2. `sin_tmux`, si la ventana no tiene sesión tmux;
    3. `sesion_no_viva`, si la sonda no vio esa sesión;
    4. el `reason` de la sonda cuando es `sin_ia`, `identidad_ambigua` o `panel_muerto`. `sin_id`
       no cuenta: la IA está y su cuenta se lee igual;
    5. si no, `account.state`: `ok`, `sin_sesion`, `no_legible` o `desconocida`.
  - `agent`: `{provider, display_name, as_root}` o `null`. `display_name` vale «Claude Code»,
    «Codex», «Antigravity», «Grok» o el id tal cual.
  - `account`: el objeto de la sonda sin `state`, porque el estado ya va en la ventana. Es `null`
    salvo que haya IA y el host se haya leído en esta llamada.

## 4. Cómo se ve, igual en las tres plataformas

| Plataforma | Dónde |
|---|---|
| Mac | Menú «UniConnect → Cuentas de IA…», justo debajo de «Acceso remoto». Abre una **ventana flotante aparte**: se mueve, cambia de tamaño (mínimo 760×520, abre a 1040×720 y recuerda dónde la dejaste) y tiene un interruptor «Siempre delante». |
| Linux | La misma entrada en el menú de la app, con la misma ventana aparte, grande y con «Siempre delante». |
| Android | Pantalla completa «Cuentas de IA», desde Ajustes. Junta todos los equipos con `accounts.v1`, y el nombre del equipo va delante del host. |

Contenido, de arriba abajo:
1. **Cabecera.** Título «Cuentas de IA», «Leído en vivo hace N s» y el botón «Actualizar» (con
   un indicador mientras lee).
2. **Filtros.** Fichas de cuenta: «Todas · N», una por email ordenadas de más a menos ventanas
   («dev@notbetting.com · 28», con su color de `paleta.json`), «Sin sesión · N» y «Sin leer · N».
   «Sin leer» cubre `no_legible`, `desconocida`, `host_inaccesible`, `sesion_no_viva` e
   `identidad_ambigua`.
   - Una ficha de email se queda **solo** con las ventanas de esa cuenta.
   - Al lado, un buscador que mira espacio, ventana, email, host y usuario del sistema.
3. **Agrupar.** «Por espacio» (por defecto) o «Por cuenta», y el interruptor «Ventanas sin IA»,
   apagado por defecto. Apagado, oculta `sin_ia`, `sin_tmux` y `panel_muerto`.
4. **Avisos de host.** Uno por host que no sea `ok`: «No se pudo leer root@…: no contestó» o
   «…: la bóveda está cerrada».
5. **Filas.**
   - Nombre de la ventana.
   - Insignia del proveedor (Claude Code / Codex / …).
   - Email en grande con su color, o el estado en gris: «Sin sesión», «No legible como root»,
     «Cuenta no expuesta», «Host sin respuesta», «Sin IA», «La sesión tmux no está viva».
   - Píldora del plan, si lo hay.
   - Debajo, en pequeño: `os_user · config`, y `host_label` cuando se agrupa por cuenta.
   - Con `method` distinto de `oauth`/`chatgpt`: «Clave de API», «Bedrock», «Vertex» o «Foundry»
     en lugar del email.
6. **Resumen por cuenta** (solo «Por cuenta»): cabecera con el email, su color, el número de
   ventanas y en cuántos hosts está.

## Quién lee qué (a 10-11-2026)

| Archivo | Lo lee hoy | Tiene que leerlo |
|---|---|---|
| `sonda-cuentas.json` | `linux/tests/test_agent_probe_accounts.py` | — |
| `accounts-response.json`, `paleta.json` | Nadie todavía | Android (decodificar y pintar), Mac y Linux (pruebas del montaje de la respuesta). |
| `accounts-request.json`, `errors.json` | Nadie todavía | Pruebas del RPC de Mac y Linux. |
