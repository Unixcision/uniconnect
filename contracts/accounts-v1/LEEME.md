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
| `barra-uso.sh` | El bloque de la barra de estado de Claude que deja el uso de la cuenta para la sonda (§2.4). |

**Ampliación del mismo día:** Dani pidió también el **porcentaje de uso de cada cuenta y cuándo
resetea**, con gráficas y una vista por pestañas: «sería lo mejor que has desarrollado en tu vida».
Eso es `account.usage` (§2.4), `accounts[]` con `history` (§3.1) y la pestaña «Uso por cuenta» (§4.1).

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
  "read_at": "2026-11-10T12:30:04Z",
  "usage": null | {"source": "statusline" | "rollout", "observed_at": "...", "limits": [
    {"id": "seven_day", "used_percent": 51.0, "resets_at": "2026-11-15T14:00:00Z", "window_minutes": 10080}
  ]}
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

### 2.4 El uso de cada cuenta (`usage`)

Lo último que **la propia IA** dijo de sus límites, con la hora en que lo dijo (`observed_at`).
Sin tokens, sin llamadas a APIs por fuera y sin refrescar credenciales: solo se leen ficheros.

- **Claude:** `uniconnect-uso.json` en `$CLAUDE_CONFIG_DIR`, o en `~/.claude` si no está.
  - Lo escribe la barra de estado (`statusLine`) en cada repintado, con el bloque `barra-uso.sh`:
    `{version: 1, email, observed_at, rate_limits}`. `rate_limits` es lo que Claude Code le pasa a
    la barra, por ejemplo `seven_day: {used_percentage, resets_at}` y `five_hour` cuando aplica.
  - **Solo vale si `email` es el de la cuenta de ahora.** Después de un `/login` con otra, el
    fichero viejo se descarta.
  - Cada clave de `rate_limits` es un límite: `id` = su nombre, `used_percent` redondeado a una
    décima y `resets_at` en ISO.
  - `window_minutes`: `five_hour` → 300, `seven_day*` → 10080; las demás, `null`.
  - Orden: `five_hour`, `seven_day` y luego el resto alfabético.
- **Codex, en vivo (`source: "app_server"`), lo primero.** Se le pregunta a **su propio Codex**:
  el mismo binario que corre en la ventana (`/proc/<pid>/exe`, o `argv[0]` en macOS) arrancado
  como `codex app-server`, con el mismo usuario y su `CODEX_HOME`.
  - Por stdio, JSON-RPC: `initialize`, luego `initialized` y luego `account/rateLimits/read`.
    Plazo de 6 s, y después se mata el grupo del proceso.
  - Es lo que hace la propia interfaz de Codex cada pocos segundos: UniConnect no toca tokens.
  - Solo si la IA corre con el mismo usuario que la sonda; nunca escribe en la carpeta de otro.
  - Una vez por `CODEX_HOME` y sonda.
  - `rateLimits.primary` y `secondary` dan `used_percent` (`usedPercent`), `window_minutes`
    (`windowDurationMins`) y `resets_at` (`resetsAt`, en segundos). `observed_at` es ahora.
  - Si Codex ofrece reseteos gratis (`rateLimitResetCredits` con `status: "available"`),
    `usage.reset_credits` = `{available, next_expires_at}`. Si no los hay, la clave no está.
  - Motivo, medido el 10-11: Codex 0.166/0.167 ya no escribe `token_count` en los rollouts, sino
    en SQLite. El rollout de una ventana activa de NOTBETTING decía 1 % del 5-11; en vivo, 62 %.
- **Codex, respaldo (`source: "rollout"`):** si no se puede preguntar en vivo, el último evento
  `token_count` con `rate_limits` de `$CODEX_HOME/sessions/**/*.jsonl`. Se recorre **todo el
  árbol**, porque un `codex resume` sigue escribiendo en el rollout del día en que nació la sesión.
  - Se miran los 6 ficheros modificados más recientemente, y de cada uno el último MiB.
  - `primary` y `secondary` con su `used_percent`, `window_minutes` y `resets_at`. Si viene
    `resets_in_seconds`, se suma a la hora del evento.
  - Si `auth.json` cambió más de 60 s **después** del evento, se descarta: puede ser de la cuenta
    anterior.
- Sin fichero, de otra cuenta o sin límites: `usage: null`. Los casos están en
  `sonda-cuentas.json` → `usos`.

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
  - `error`: por qué no se pudo leer, o `null` si se leyó. Valores:
    - `sin_respuesta`: venció el plazo;
    - `sin_python3`: código 127 o «python3: not found»;
    - `ssh_fallo`: código 255 o sin credencial válida;
    - `salida_no_valida`: ninguna línea de la salida es la de la sonda;
    - `tmux_no_disponible` o `tmux_fallo`: el `error` de la propia sonda.

    `error_detail`: la última línea útil de lo que dijo SSH o el shell (como mucho 160 caracteres,
    sin avisos ni prompts), o lo que falló en el propio equipo antes de conectar («UniConnect no
    encuentra la credencial SSH de esta caja», «no pudo preparar la orden ssh con contraseña
    (¿sshpass?)»…). Va detrás del aviso: «… falló la conexión SSH · Permission denied (password)».

    El aviso lo dice con esas palabras: «no contestó a tiempo», «no tiene python3», «falló la
    conexión SSH», «respondió algo que no es la sonda», «no tiene tmux», «tmux dio un error».
  - **La salida se lee por su última línea que sea un objeto JSON.** Un shell remoto que imprime
    un saludo antes de la sonda no puede tapar la respuesta.
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
- `accounts`: una por **proveedor + email**. `it@iberiavo.com` en Claude y en Codex son dos.
  Salen solo las ventanas `ok` con email, ordenadas por número de ventanas (de más a menos) y
  luego por email. Ver §3.1.

### 3.1 `accounts[]`, uso e histórico

```json
{"key": "claude:dev@notbetting.com", "provider": "claude", "display_name": "Claude Code",
 "email": "dev@notbetting.com", "plan": "Ultra", "organization": "...", "windows": 34,
 "host_keys": ["local", "ssh:root@203.0.113.10:22"],
 "usage": {"source": "statusline", "observed_at": "...", "host_key": "local", "limits": [...]} | null,
 "history": [{"at": "2026-11-10T12:29:58Z", "limits": {"seven_day": 51.0, "five_hour": 3.5}}]}
```

- `usage`: de todas las ventanas de esa cuenta, el uso con el `observed_at` **más reciente**,
  más el `host_key` donde se vio.
- `history`: muestras que guarda el escritorio, de más vieja a más nueva, de los **últimos 7 días**.
  - Cada vez que el `usage` elegido trae un `observed_at` posterior a la última muestra de esa
    cuenta, se añade `{at: observed_at, limits: {id: used_percent}}`. Si cae a menos de 5 min de
    la anterior, la sustituye.
  - Se guarda en disco y se conservan 14 días:
    - Mac: `~/Library/Application Support/UniConnect/accounts-usage-history.json`;
    - Linux: `~/.local/state/uniconnect/accounts-usage-history.json`.
  - El histórico es lo único que se recuerda entre llamadas, y se enseña **como histórico**, con
    sus fechas. El estado actual de las ventanas sigue siendo siempre de la lectura de ahora.

## 4. Cómo se ve, igual en las tres plataformas

| Plataforma | Dónde |
|---|---|
| Mac | Menú «UniConnect → Cuentas de IA…», justo debajo de «Acceso remoto». Abre una **ventana flotante aparte**: se mueve, cambia de tamaño (mínimo 760×520, abre a 1040×720 y recuerda dónde la dejaste) y tiene un interruptor «Siempre delante». |
| Linux | La misma entrada en el menú de la app, con la misma ventana aparte, grande y con «Siempre delante». |
| Android | Pantalla completa «Cuentas de IA», desde Ajustes. Junta todos los equipos con `accounts.v1`, y el nombre del equipo va delante del host. |

Contenido, de arriba abajo:
1. **Cabecera.** Título «Cuentas de IA», «Leído en vivo hace N s» y el botón «Actualizar» (con
   un indicador mientras lee).
2. **Filtro por IA** (pedido el 10-11). Una fila «IA: Todas las IA · 56 · Claude Code 44 ·
   Codex 8 · Grok 1»: una ficha por cada `agent.provider` que **haya** en esta lectura, con su
   `display_name` y su número de ventanas, de más a menos. No hay lista fija: si mañana aparece otra IA,
   sale sola. Solo cuentan las ventanas leídas ahora, de los equipos conectados y autorizados: un host que
   no contestó no aporta IAs.
   - Se combina con todo lo demás: elegir «Codex» deja en las fichas de cuenta solo cuentas de Codex,
     y en «Uso por cuenta» solo esas cuentas.
   - Al cambiar de IA, la ficha de cuenta vuelve a «Todas».
3. **Filtros por cuenta.** Fichas de cuenta: «Todas · N», una por email ordenadas de más a menos ventanas
   («dev@notbetting.com · 28», con su color de `paleta.json`), «Sin sesión · N» y «Sin leer · N».
   «Sin leer» cubre `no_legible`, `desconocida`, `host_inaccesible`, `sesion_no_viva` e
   `identidad_ambigua`.
   - Una ficha de email se queda **solo** con las ventanas de esa cuenta.
   - Al lado, un buscador que mira espacio, ventana, email, host y usuario del sistema.
4. **Agrupar.** «Por espacio» (por defecto) o «Por cuenta», y el interruptor «Ventanas sin IA»,
   apagado por defecto. Apagado, oculta `sin_ia`, `sin_tmux` y `panel_muerto`.
5. **Avisos de host.** Uno por host que no sea `ok`: «No se pudo leer root@…: no contestó» o
   «…: la bóveda está cerrada».
6. **Filas.**
   - Nombre de la ventana.
   - Insignia del proveedor (Claude Code / Codex / …).
   - Email en grande con su color, o el estado en gris: «Sin sesión», «No legible como root»,
     «Cuenta no expuesta», «Host sin respuesta», «Sin IA», «La sesión tmux no está viva».
   - Píldora del plan, si lo hay.
   - Debajo, en pequeño: `os_user · config`, y `host_label` cuando se agrupa por cuenta.
   - Con `method` distinto de `oauth`/`chatgpt`: «Clave de API», «Bedrock», «Vertex» o «Foundry»
     en lugar del email.
7. **Resumen por cuenta** (solo «Por cuenta»): cabecera con el email, su color, el número de
   ventanas y en cuántos hosts está.

### 4.1 Pestaña «Uso por cuenta»

Arriba hay un selector «Ventanas | Uso por cuenta». La primera es todo lo anterior. La segunda:

- **Una pestaña por cuenta** (ficha con email, color y mini-anillo del límite más alto) y una
  primera pestaña «Resumen» con todas en rejilla.
  - Mac y Linux: lista lateral de cuentas + detalle.
  - Android: pestañas desplazables arriba.
- **Detalle de una cuenta:**
  - Cabecera con el email en su color, el proveedor, la píldora del plan y «En N ventanas ·
    M hosts».
  - **Una tarjeta por límite** con anillo y porcentaje en grande:
    - el nombre: `five_hour` «5 horas», `seven_day` «Semana», `seven_day_opus` «Semana · Opus»,
      `seven_day_sonnet` «Semana · Sonnet» y `seven_day_fable` «Semana · Fable». Codex usa la
      ventana: 300 «5 horas», 10080 «Semana» y otra cifra «N h»;
    - «Resetea en 2 d 3 h · sáb 15:00» (hora local);
    - «Visto hace 4 min en Este Mac».
  - **Gráfica** de los 7 días de `history`: una línea por límite, de 0 a 100 %, con el reset
    marcado.
  - **Estadística:**
    - **ritmo:** puntos por día dentro de la ventana actual;
    - **proyección:** «A este ritmo, llegarás al 87 % antes del reset», o «Se agotaría el jue
      13:20» si pasa de 100.
  - **Dónde está:** hosts y ventanas que usan esa cuenta, con un toque que lleva a esa ventana
    en la pestaña «Ventanas».
- **Frescura en el uso:**
  - con `reset_credits`: «2 reseteos gratis disponibles · el primero caduca el 30 nov»;
  - si `resets_at` ya pasó, el límite sale a **0 %** con «Reseteado el … · sin uso nuevo visto»;
  - si `observed_at` tiene más de 1 h, la edad sale en ámbar: «Dato de hace 3 h»;
  - sin `usage`: «Sin datos de uso todavía». Claude: «aparecen en cuanto esta cuenta trabaje en
    una ventana con la barra de estado de UniConnect». Codex: «en cuanto Codex haga una petición».
- **Ritmo y proyección**, la misma fórmula en todas las plataformas:
  1. Se usan las muestras de `history` de ese límite dentro de la ventana actual (`at >=
     resets_at - window_minutes`), más el `usage` actual.
  2. Hacen falta al menos 2 separadas 30 min o más. Si no, no se pinta ninguna de las dos.
  3. `ritmo` = (último − primero) / horas entre ellos.
  4. `proyección` = actual + ritmo × horas hasta `resets_at`.
  5. Si es ≥ 100, el agotamiento se da en el instante actual + (100 − actual) / ritmo.

## 5. Gastar un reseteo gratis de Codex

Codex da reseteos gratis por cuenta (`usage.reset_credits`). Dani pidió el 10-11 poder gastarlos
desde las apps. Es la **única acción que escribe** en todo `accounts-v1`, y siempre va con
confirmación.

- **Llamada:** `mobile.accounts.codex_reset`; en el socket de escritorio, `accounts.codex_reset`.
  - Capacidad: `accounts.codex_reset.v1`.
  - Parámetros: `{account_key, host_key, idempotency_key}`. `account_key` es
    `codex:<email>`; `idempotency_key` es un UUID generado **una vez por confirmación** y reutilizado
    si se reintenta.
- **Qué hace el equipo:**
  1. Lee las cuentas en ese momento y elige la primera ventana `ok` de esa cuenta en ese host.
  2. Lanza allí la sonda con `--session <su tmux> --codex-reset <idempotency_key>`.
  3. La sonda llama al app-server de ESE Codex, con el mismo binario, usuario y `CODEX_HOME`:
     `account/rateLimitResetCredit/consume {idempotencyKey}` y después `account/rateLimits/read`.
     Plazo de 8 s.
- **Respuesta:** `{account_key, host_key, outcome, usage}`.
  - `outcome` es lo que dice Codex: `reset`, `nothingToReset` (no había nada que resetear y no se
    gasta nada), `noCredit` o `alreadyRedeemed` (esa misma clave ya lo aplicó).
  - `usage` es el uso de después, o `null`.
- **Errores:** `invalid_params`, `locked`, `not_found` (no hay ninguna ventana de esa cuenta en ese
  host) y `unavailable` (el host no contestó, o no hay Codex al que preguntar).
  - La salida de la sonda trae `codex_reset: {error}`, con `sesion_no_encontrada`, `no_es_codex`,
    `codex_no_disponible` o `codex_no_contesto`.
- **En las apps:** en «Uso por cuenta» de una cuenta de Codex con `reset_credits.available > 0`, el
  botón «Usar un reseteo gratis».
  - Antes, una confirmación: «¿Gastar 1 de N reseteos gratis de <email>? Los límites de Codex de
    esta cuenta vuelven a 0 %. No se puede deshacer.», con «Gastar reseteo» y «Cancelar».
  - Después, según `outcome`:
    - `reset`: «Hecho: <email> vuelve a empezar.»;
    - `nothingToReset`: «No había nada que resetear: no se ha gastado ninguno.»;
    - `noCredit`: «Esta cuenta ya no tiene reseteos gratis.»;
    - `alreadyRedeemed`: «Ese reseteo ya se había aplicado.»

  Y se vuelven a leer las cuentas.

## Quién lee qué (a 10-11-2026)

| Archivo | Lo lee hoy | Tiene que leerlo |
|---|---|---|
| `sonda-cuentas.json` | `linux/tests/test_agent_probe_accounts.py` | — |
| `accounts-response.json`, `paleta.json` | Nadie todavía | Android (decodificar y pintar), Mac y Linux (pruebas del montaje de la respuesta). |
| `accounts-request.json`, `errors.json` | Nadie todavía | Pruebas del RPC de Mac y Linux. |
