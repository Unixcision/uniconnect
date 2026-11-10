# Ejemplos normativos de `relaunch.v1`

Estos archivos **son el contrato**, no una ilustración. Las pruebas de Mac, Linux y Android leen
estos mismos ficheros; si un ejemplo y una implementación discrepan, manda el ejemplo.

El documento que los explica es `docs/RELANZAR-v1.md`.

| Archivo | Qué fija |
|---|---|
| `plan-request.json` | Forma de `relaunch.plan`. |
| `plan-response.json` | Objetivos, exclusiones con causa, token y caducidad. |
| `apply-request.json` | Forma de `relaunch.apply`. |
| `apply-response.json` | Resultado por objetivo de un `apply` que sí ejecutó. |
| `apply-recovered-response.json` | Un `apply` repetido de una operación ya aceptada: `recovered: true`, no se ejecuta nada nuevo, y vale aunque el token haya caducado. |
| `apply-in-progress-response.json` | `apply` no bloquea hasta terminar: devuelve con `operation_state: "en_curso"` y el cliente sigue con `relaunch.status`. |
| `status-request.json` | Forma de `relaunch.status`. |
| `errors.json` | Errores de la llamada, distintos de las causas por objetivo. |
| `plan-update-request.json`, `plan-update-response.json`, `apply-update-response.json` | Actualizar Claude (`agent.update`), monitores, borradores y coste (09-11-2026). |
| `mensajes.json` | Textos exactos que se escriben en la IA tras reabrirla, y cuándo. |
| `causes.json` | Causas estables por objetivo. El texto en español lo pone el cliente. |
| `proveedores.json` | Qué IA sabe relanzar cada equipo por tipo de ventana (tras D7), y los tokens con los que lo anuncia. |

## Quién lee qué (a 24-09-2026)

Solo lo que existe en el repositorio. Afirmar una lectura que no ocurre es peor que no apuntarla:
da por vigilado un fichero que nadie mira.

| Archivo | Lo lee hoy |
|---|---|
| `causes.json` | Android: `RelaunchTest` exige que `RelaunchCause` sea exactamente este conjunto. Mac: `RelaunchCauseCatalogueTests` (sube hasta encontrar `contracts/` y hace `#require`; desde el 09-11-2026 compara de verdad y `RelaunchCause` es exactamente este conjunto). |
| `plan-response.json`, `plan-all-excluded-response.json`, `plan-blocked-response.json` | Android: `RelaunchPlanContractTest`. |
| `plan-window-request.json` | Android: `AgentCatalogCodecTest`. Linux: `linux/tests/test_relaunch.py`. |
| `apply-response.json`, `apply-recovered-response.json`, `apply-in-progress-response.json` | Android: `RelaunchOperationContractTest` (si terminó lo dice `operation_state`, no `recovered`). Linux: `test_relaunch.py` compara las claves de su `apply` con las de `apply-in-progress-response.json`. |
| `plan-request.json` | Linux: `test_relaunch.py` resuelve su alcance. |
| `proveedores.json` | Mac: `RelaunchDialectTests` (lo que anuncia es exactamente su fila de `capacidades`, y sus celdas de `equipos`). Lo tienen que leer también Linux y Android (cuándo ofrece «Relanzar IA de esta ventana»). |
| `errors.json` | Mac: `RelaunchUpdateOptionsTests` (cada error que usa el Mac está aquí). |
| `apply-request.json`, `status-request.json` | Nadie todavía. |
| `plan-update-request.json`, `plan-update-response.json`, `apply-update-response.json` | Android: `RelaunchUpdateContractTest` (09-11-2026). Mac: `RelaunchUpdateContractTests` (mismas claves por objetivo y por resultado, `estimated_tokens`, `updates[]`) y `RelaunchUpdateOptionsTests`. Linux: pendiente. |
| `mensajes.json` | Mac: `RelaunchReopenMessageTests` (los textos letra a letra, y cuándo se manda). |

Las pruebas de Android se han escrito o cambiado el 24-09-2026 sin ejecutarlas: no se compila
hasta nuevo aviso.

Causas añadidas: `sin_ia` (24-09-2026), para una ventana sin ninguna IA en marcha. Ya llegaba en
`plan-all-excluded-response.json` y Android la conoce (`RelaunchCause.NO_AGENT`). El Mac
(`RelaunchCause` en `Packages/CMUXAgentLaunch`) todavía no.

Dos campos que se confunden y no son lo mismo: **`recovered`** dice que la operación **ya existía**,
y **`operation_state`** dice si **terminó**. Una operación recuperada puede seguir en curso.

Regla que se comprueba con `apply-recovered-response.json`: **recuperar el resultado de algo que ya
se hizo no puede exigir un plan nuevo.** Si lo exigiera, un corte de red entre el cierre y la
respuesta se convertiría en trabajo perdido, que es justo lo que este contrato existe para evitar.

Y una que se comprueba mirando quién pide: la excepción de caducidad al recuperar es **solo a la
caducidad**. Sigue haciendo falta un dispositivo autorizado ahora y que sea el dueño de esa
operación. Un token caducado no es una llave maestra.

## Qué relanza cada equipo (D7, 24-09-2026)

Antes de D7 el Mac solo sabía cerrar Claude y Linux solo Codex, y los dos anunciaban `relaunch.v1`
igual. D7 porta el dialecto que falta a cada lado. La matriz resultante, que fija
`proveedores.json`:

| Proveedor | Mac, ventana local | Mac, ventana SSH | Linux, ventana local | Linux, caja SSH |
|---|---|---|---|---|
| Claude | sí (10-11, en vivo: salida limpia, escalado con monitores y con borrador, actualizar) | sí, por el trabajador de Linux (10-11, en vivo en `uc-prueba-relanzar`) | sí (probado en vivo el 08-11: salida limpia y, ocupado, escalado a matar el proceso; misma conversación y mismas opciones) | sí (probado en vivo el 08-11 en DESA por el camino real del adaptador: salida limpia en 7 s, misma conversación y mismas opciones) |
| Codex | escrito, **pendiente de prueba en vivo** | sí, por el trabajador de Linux (10-11, en vivo en NOTBETTING con Codex 0.166 `--yolo`: mismo hilo, mismo binario, «Skip» del aviso de actualización anotado en el diario) | sí, `agent.continue` y `agent.recover` requieren evidencia exacta de pausa/acuse | sí |
| Antigravity | `no_soportado` | `no_soportado` | sí, solo con binding gestionado y statusLine nativo fresco que pruebe estado idle | sí, bajo las mismas puertas en el destino Linux |

«Pendiente de prueba en vivo» (decisión del 24-09-2026): el dialecto está escrito y probado con
dobles, pero relanzar **cierra la IA** y nunca se ha ejecutado contra una real. Hasta esa prueba no
se anuncia y el plan lo excluye con `no_soportado` (`pendiente_prueba_en_vivo` en
`proveedores.json`). Se activa añadiéndolo a `RelaunchDialects.known` (Mac) o a `RELAUNCHABLE`
(Linux) en el mismo commit que la prueba. Antigravity ya pasó además una fixture aislada de tmux
que cierra y reabre un proceso sintético con la misma conversación y configuración; no se ha
operado una cuenta real.
| grok y el resto del catálogo | `no_soportado` | `no_soportado` | `no_soportado` | `no_soportado` |

- **Mac SSH** (10-11): Claude se relanza y se actualiza ejecutando por SSH el trabajador de Linux
  (ver «Mac y SSH»). Codex también (10-11, probado en vivo); Antigravity sigue fuera desde el Mac
  (`proveedor_no_soportado`) hasta que haya un binario con el que probarlo. Una ventana SSH pedida
  por id desde el móvil devuelve su plan o su exclusión, nunca `alcance_no_valido`.
- **Linux SSH** usa el mismo trabajador que en local, ejecutado en el destino por el canal de la
  caja. Necesita un destino Linux (`/proc` y `pidfd_open`); si no los hay, `no_soportado`.

### Lo que exige cada dialecto (igual en las dos plataformas)

> **08-11-2026:** el cierre, el escalado y las opciones con que se reabre los fija ahora la sección
> «Escalado y mismas opciones» del final. Donde abajo dice «sin matarlo», «nunca Ctrl+C» o
> «con la política `noPrompt`», manda esa sección.

- **Claude** (el Mac ya lo tiene en `ClaudeRelaunchDialect`; Linux lo calca):
  - Identidad probada antes de cerrar. El Mac usa `RelaunchIdentityEvidence` (un único candidato
    entre cerrojos, rollouts y un hook que coincide en proceso y panel) y el id que Claude imprime al
    salir («Resume this session with»). Linux (D7) solo lo intenta con la ficha
    `~/.claude/sessions/<pid>.json` de la raíz en `status: "idle"`. Sin identidad probada:
    `identidad_ambigua`.
  - Solo con el compositor vacío. Linux, si la ficha no está en `idle` o el compositor no está vacío,
    excluye sin tocar nada con `dialogo_desconocido`, la misma causa que ya usa su trabajador de
    Codex. Un diálogo de confianza de carpeta es `confianza_carpeta`; uno de permisos, `permisos`.
    Nunca se contesta por nadie. La pregunta de trabajo en segundo plano se resuelve eligiendo la
    opción por su texto, nunca por su posición (`RelaunchScreenReading`).
  - Cierra escribiendo `/exit` (nunca Ctrl+C) y comprobando la línea antes de Intro.
  - Reabre con `[IS_SANDBOX=1 ]claude --resume <id> <opciones vivas saneadas>
    --dangerously-skip-permissions`, con la política `noPrompt` del catálogo. `IS_SANDBOX=1` solo si
    la raíz es de root (en el Mac local, nunca).
  - `verificado` exige un proceso nuevo con la **misma** conversación.
- **Codex** (Linux ya lo tiene en `TargetWorker.exit_codex`; el Mac lo calca):
  - Identidad: el rollout que tiene abierto (regla de `contracts/agent-tree-v1`).
  - Compositor vacío: `›` solo, o el marcador atenuado «› Ask Codex to do anything» con el cursor en
    la columna 2. Si en pantalla hay una pregunta de permisos o de confianza, `permisos`.
  - Cierra escribiendo `/exit` literal, espera a ver «› /exit» en la línea del cursor, y solo
    entonces Intro. Espera a que el proceso muera (≤ 75 s) sin matarlo; si no muere,
    `dialogo_desconocido`.
  - Reabre con `codex --yolo resume <id> <opciones conservadas>`, con `supersedes` aplicado (quita
    `-a`, `--ask-for-approval`, `-s`, `--sandbox`, `--full-auto`).
  - `verificado` exige la misma conversación viva otra vez.
- El Mac guarda el id verificado con el **proveedor del objetivo** (`recordRelaunchedConversations`),
  nunca con `claude` fijo.

### Cómo lo anuncia el equipo

Actualización de Linux (01-10-2026, Codex): el plan puede incluir un objetivo con
`active: true` cuando reconoce trabajo o terminales de fondo y ha comprobado su
identidad, configuración efectiva y compositor vacío. Es un aviso, no una causa
de exclusión: **Aplicar** autoriza interrumpir ese trabajo y relanzar la misma
conversación. El escritorio muestra el aviso antes de confirmar. El trabajador
solo envía Esc ante los indicadores reconocidos «Working» o «Waiting for
background terminal» con «esc to interrupt», y
observa el final nativo del turno antes de `/exit`. No fuerza la muerte del proceso.

La configuración y el ciclo de turno se leen del archivo nativo acreditado de
esa conversación, retrocediendo hasta el contexto más reciente aunque quede
fuera de los últimos 4 MiB. No se descartan finales de turno por incluir una
respuesta larga. Una instancia recién reanudada también puede acreditar reposo
con su configuración nativa completa posterior al nacimiento del proceso y sin
actividad nativa posterior a ese nacimiento; un contexto antiguo interrumpido
no obliga a inventar un final. Los relojes ambiguos o metadatos insuficientes
bloquean esa vía. La pantalla por sí sola nunca acredita la configuración.

El compositor vacío de Codex en Linux se reconoce por el marcador atenuado o
gris y su estructura, sin exigir la columna 2 del cursor. Un borrador o un estado
ambiguo sigue bloqueando el cierre. Antes de Intro, la línea `/exit` y el resto
del compositor deben coincidir con la entrada esperada; se revalidan también
proceso, conversación y configuración. Que un objetivo activo termine su turno
no invalida por sí solo el plan confirmado. Estos cambios no amplían el soporte
de otros proveedores ni modifican los dialectos de macOS.

En `capabilities` (de `mobile.workspace.list`, de `mobile.host.status` en Linux y del `status` del
socket de control de Linux), además de `relaunch.v1`, un token por celda soportada:
`relaunch.v1.<proveedor>.<tipo>`, con `<tipo>` `local` o `ssh`. La lista exacta de cada equipo es
su fila de `capacidades` en `proveedores.json`.

- Un equipo solo anuncia una celda cuando su dialecto está hecho y probado. El token es una pista
  para la interfaz, no una autorización: el plan sigue excluyendo con causa lo que no puede hacer.
- Android, con `relaunch.v1` y **algún** token `relaunch.v1.*.*`: ofrece «Relanzar IA de esta
  ventana» solo si está anunciado el par (proveedor, tipo) de la ventana; si no sabe el proveedor de
  la ventana, lo ofrece cuando hay algún token de su tipo. Con `relaunch.v1` y **ningún** token
  (equipo anterior a D7), lo ofrece como hasta ahora y deja que el plan excluya.
- Los alcances `workspace` y `machine` se ofrecen con `relaunch.v1` a secas: el plan enseña lo que
  entra y lo que no, con su causa.

## Escalado y mismas opciones (decisión de Dani, 08-11-2026)

Sustituye a la regla «nunca matar tmux» (que pasa a «nunca matar el **servidor** tmux») y a la de
reabrir siempre sin preguntas del 24-09. Acordado en `coordNov` entre la IA del Mac y la de Linux.

### Escalado, por objetivo, tras `apply`
1. **Salida limpia** del dialecto (`/exit`; Ctrl+D en agy), comprobada en pantalla como hasta
   ahora. Espera acotada de **60 s** a que muera el proceso.
2. **Matar el proceso**: SIGTERM al grupo del proceso de la IA (ella y sus hijos, nunca el shell del
   pane), 5 s, y SIGKILL. Si el pane conserva su shell, la orden de reanudar se escribe ahí.
3. **`respawn-pane -k -t <pane> -c <cwd> 'exec "${SHELL:-/bin/sh}" -l'`** y se escribe la orden de
   reanudar en ese shell, como al crear. **Con esa orden explícita**: sin orden, tmux vuelve a
   ejecutar la orden con la que se creó el pane (medido el 08-11 en tmux 3.4), que en UniConnect es
   el arranque antiguo de la IA con sus opciones viejas. Se usa si tras el paso 2 no queda un shell
   donde escribir (la IA era la raíz del pane, o la lanzó un supervisor). Conserva la sesión, su
   nombre, la ventana tmux y lo que esté enganchado.
4. **`kill-session` y recrear** la sesión con el mismo nombre, socket y cwd, con la orden de reanudar
   dentro, solo si `respawn-pane` falla. Si la sesión tiene otro pane u otra ventana ajenos, **no**
   se mata: `sesion_compartida`.
5. Si al aplicar la sesión tmux ya no existe, se recrea directamente (paso 4 sin matar nada).

**Nunca el servidor tmux entero.** El resultado por objetivo lleva `escalation`: `exit`,
`kill_process`, `respawn_pane` o `recreate_session` (el último paso que hizo falta). Cada paso deja
una línea de `log-v1` (`relaunch.exit_sent`, `relaunch.exit_timeout`, `relaunch.kill_process`,
`relaunch.kill_session`, `relaunch.session_recreated`, `relaunch.resumed`).

### Avisos del plan, no exclusiones
Un objetivo planificado puede llevar `active: true` y `warning` con la causa: `tareas_de_fondo`
(tareas, terminales de fondo o monitores) o `permisos` (esperaba una respuesta de permisos). Aplicar
autoriza pararlo: el escalado lo cierra y la conversación se reanuda; se pierde la llamada
pendiente, no la conversación. El escritorio y el móvil enseñan el aviso antes de confirmar.

Siguen **excluyendo** (nunca se adivina):
- `identidad_ambigua`: sin saber qué conversación es, no se mata nada.
- `confianza_carpeta`: es un diálogo de arranque. Si aparece **después** de reabrir, el resultado es
  `necesita_usuario` con esa causa y nunca se contesta a ciegas.

### Mismas opciones
- Se reabre con las opciones **vivas** del proceso (`/proc/<pid>/cmdline`, quitando solo el
  selector de conversación), y con `IS_SANDBOX=1` solo si estaba en su entorno.
- Si el proceso ya no existe (recuperación tras un apagado), con las **guardadas** en el árbol
  (`agent.launch`, ver `contracts/agent-tree-v1`).
- Solo si no hay ninguna de las dos, la política `noPrompt` del catálogo, como antes.
- Una IA lanzada sin bypass vuelve sin bypass y puede pararse a pedir permiso: es lo que pidió Dani.
- Codex conserva `-a`, `-s` y `--full-auto` tal cual; `--yolo` ya no los sustituye cuando se reabre
  con opciones conocidas.

**Lista blanca por proveedor.** Solo se conservan estas opciones. Vive en el catálogo
`agent-resume-v1.json` (`launchOptions`), que la edita el Mac y la leen las dos plataformas.
- claude: `--model`, `--effort` (desde el 09-11), `--fallback-model`, `--permission-mode`, `--dangerously-skip-permissions`,
  `--allow-dangerously-skip-permissions`, `--add-dir` (repetible), `--chrome`, `--verbose`, `--settings`,
  `--setting-sources`, `--mcp-config`, `--strict-mcp-config`, `--allowedTools`, `--disallowedTools`,
  `--tools` (rutas y nombres, no texto libre). Nunca `--system-prompt` ni `--append-system-prompt`.
- codex: `-m`/`--model`, `-c`/`--config clave=valor` (salvo claves con `key`, `token`, `secret`,
  `password` o `auth`), `-a`/`--ask-for-approval`, `-s`/`--sandbox`, `--full-auto`, `--yolo`,
  `--dangerously-bypass-approvals-and-sandbox`, `-C`/`--cd`, `-p`/`--profile`, `--search`, `--add-dir`,
  `--enable`, `--disable`, `--no-alt-screen`.
- agy: `--dangerously-skip-permissions` y las que ya conserva hoy el trabajador de Linux.
- grok: ninguna verificada.

Cualquier otra opción se **quita**, se relanza igual y se informa: `dropped_options` en el
resultado (solo el nombre de la bandera, nunca su valor) y `relaunch.option_dropped` (`warn`) en el
log. Nunca se conservan prompts posicionales, `--api-key`, tokens, `-c` con otras claves ni
ninguna variable de entorno salvo `IS_SANDBOX`. (Las listas incluyen lo que el trabajador de Linux ya
conservaba antes del 08-11: quitarlo haría volver a una IA sin su MCP o sus herramientas.)

### Causas nuevas (`causes.json`)
`no_soportado` queda solo para «el equipo no anuncia relaunch.v1». Lo que tapaba ahora tiene nombre:
`proveedor_no_soportado`, `sin_tmux`, `sin_credencial`, `destino_no_linux`, `carpeta_inexistente`,
`binario_no_encontrado` y `sin_pausa` (continuar Codex sin aviso de cuota). Y una nueva por el
escalado: `sesion_compartida`. Un cliente que no conozca una causa enseña un texto genérico.
`plan-response.json` y `apply-response.json` traen ya un aviso, el escalado y `dropped_options`.

## Actualizar Claude, monitores y borradores (decisión de Dani, 09-11-2026)

Nace del reciclado a mano de 47 Claude del 09-11 (Mac, MINIPC, NOTBETTING, NOLEAKOS, XUNIS,
IBERIAVO). Lo que se aprendió ahí es ahora regla para los dos botones:

- **Relanzar IA** (`agent.relaunch`): cualquier proveedor, mismas opciones.
- **Actualizar Claude** (`agent.update`): solo Claude. Es el mismo proceso más `claude update` y,
  si se piden, modelo y effort.

Nada de lo que sigue cambia las fases, el token ni el escalado de arriba.

### `agent.update`
- **Petición.** `plan-update-request.json`. `options` es opcional:
  - `model`: alias o id de Claude, `^[a-z0-9.\-\[\]]{2,40}$`.
  - `effort`: `low`, `medium`, `high`, `xhigh` o `max`.
  - La clave que falta significa «igual que estaba».
  - Con `agent.relaunch`, `options` no vale: error `opciones_no_validas`. Relanzar no cambia nada.
- **Proveedores.** Un objetivo que no sea Claude se excluye con `proveedor_no_soportado`.
- **Actualización.**
  - `claude update` corre **una sola vez por instalación**, es decir, por equipo destino, usuario
    y binario. Va **antes de cerrar nada** de esa instalación y fuera del panel (SSH aparte en
    remoto, `Process` en local).
  - Los procesos vivos no se ven afectados: siguen con su binario hasta que se reabren.
  - Resultado en `updates[]` con `host`, `state` (`actualizado`, `ya_al_dia` o `fallida`), `from`
    y `to`.
  - Si falla, los objetivos de esa instalación terminan en `omitido` con `actualizacion_fallida` y
    **no se cierran**.
- **Reapertura.** Se reabre con el lanzador estable (`~/.local/bin/claude`, o el `claude` que
  resolvía el panel), nunca con la ruta de `versions/<x>`. Si no, volvería el binario viejo.
- **Modelo y effort.** Se añaden a la orden como `--model '<m>'` y `--effort <e>`, sustituyendo las
  que tuviera. **Al reanudar, Claude recupera el modelo de la conversación e ignora el de
  `settings.json`** (medido en PREPRO el 09-11): sin `--model` explícito el modelo no cambia. Si la
  IA la lanza un supervisor (`recovery.py launch`), que no admite opciones, el modelo y el effort se
  fijan después escribiendo `/model <m>` y `/effort <e>`, cada uno con el compositor vacío y la IA
  ociosa.

### Para los dos verbos: lo que se guarda y se devuelve
- **Identidad de la ficha.** `~/.claude/sessions/<pid>.json` solo vale si su `procStart` coincide
  con el arranque del proceso: campo 22 de `/proc/<pid>/stat` en Linux; en el Mac, `startedAt` frente
  al arranque del proceso, con ±2 s. Si no coincide, `identidad_ambigua`. En el MINIPC había fichas
  de otro arranque con el PID reutilizado, y una decía ser la conversación de otra ventana.
- **Conversación compartida.** Si dos procesos Claude vivos del mismo usuario tienen el mismo
  `sessionId`, se excluyen los dos con `conversacion_compartida`. Al reanudar se abre la rama más
  reciente, y una de las dos perdería su hilo (XUNIS, claudebets/xunis_stats).
- **Login.** Antes de cerrar nada de una instalación, `claude auth status` (JSON) tiene que decir
  `loggedIn: true`. Si no, sus objetivos salen con `sin_login`: reabrir sin login deja una ventana
  inservible (IBERIAVO-DESA).
- **Monitores y shells de fondo.**
  - Son los hijos directos del proceso Claude que sean su envoltorio de Bash: un shell con
    `eval '<orden>'` cuyo prólogo lleva `unsetenv` o `shell-snapshots`, con o sin `-l`. Los MCP no
    cuentan.
  - Antes de cerrar se guarda cada `<orden>`, extraída con un analizador de comillas de shell, en
    `~/.local/state/uniconnect/relaunch-v1/monitores/<id de conversación>-<AAAAMMDD-HHMMSS>.txt` del
    destino (10-11: el id de la conversación, que es lo que la IA reconoce como suyo, no el de la
    ventana). También se copian los ficheros de `/tmp/claude-<uid>/…` que mencionen: el scratchpad
    puede no sobrevivir.
  - Formato común (10-11), igual en Mac y Linux:
    ```text
    # sesion=<tmux> conversacion=<id> estado=<status> fecha=<ISO-8601>
    # Monitor o shell de fondo 1
    <orden tal cual>
    # (copia de <ruta> en <carpeta>/)
    ```
  - El plan lo cuenta en `background`, y es **aviso** (`tareas_de_fondo`), no exclusión.
  - Tras el cierre se termina el árbol entero de cada uno, para que no queden huérfanos que dupliquen
    el monitor cuando la IA lo relance.
- **Borrador.**
  - El texto del usuario en el compositor (no el gris atenuado, que es una sugerencia) se guarda
    antes de cerrar.
  - Tras `verificado` se reescribe en el compositor **sin Intro**: `draft: true` en el plan y
    `draft_restored` en el resultado.
  - Nunca se teclea `/exit` sobre un borrador: si hay borrador, el cierre va directamente por el
    paso 2 del escalado.
- **Mensaje tras reabrir: solo si hace falta.** Reabrir no gasta cupo; lo que gasta es el mensaje,
  porque obliga a releer la conversación entera, y sin caché si cambió el modelo. El 09-11 eso se
  comió el 37 % del cupo de Fable. Por eso:
  - Con monitores, o si estaba trabajando, se escribe el texto de `mensajes.json`
    (`con_monitores`, `solo_cortado`, `anadido_cortado`), con el compositor vacío, y después Intro.
  - «Estaba trabajando» es **solo** `status: busy` (10-11). Claude escribe `shell` mientras corre un
    shell de fondo con la IA ociosa (medido en 2.1.321): se cierra por `kill_process`, como todo lo
    que no es `idle`, pero recibe `con_monitores` sin `anadido_cortado`. `solo_cortado` solo con
    `busy`.
  - Si no, no se escribe nada (`message: false`).
  - El borrador se reescribe **después** del mensaje.
- **Coste.**
  - Cada objetivo lleva `context_tokens`: `input_tokens + cache_creation_input_tokens +
    cache_read_input_tokens` del último `usage` de su `.jsonl`, leído desde el final; `null` si no
    se sabe.
  - El plan suma en `estimated_tokens` los de los objetivos con `message: true`.
  - Los clientes lo enseñan antes de confirmar.
- **Diálogo de confianza.** Rige lo de arriba: se resuelve **por su texto**, nunca por posición
  (viene con «No, exit» marcado). Si el equipo lo responde, solo puede ser para la carpeta donde
  esa misma conversación ya corría. En cualquier otro caso, `necesita_usuario`.

### Diálogos de Codex 0.166+ al reabrir (coordNov, 10-11)
Medido en NOTBETTING con un Codex 0.166 desechable. Codex 0.166 ya no deja abierto ni el rollout ni el
cerrojo: la identidad sale de la tabla `threads` (la regla de `agent-tree-v1`) y la configuración, del
rollout que da `threads.rollout_path`, que sigue escribiendo. Su TUI arranca `codex app-server` como
hijos, que no cuentan como la IA del panel.
- **«Update available» → «Skip»**, la de solo esta vez, **por su texto y nunca por posición**. Jamás
  «Update now» ni «Skip until next version». Solo si el diálogo está vivo (sus tres opciones justo
  encima de «enter continue · esc skip», al final de la pantalla), solo durante la verificación de un
  relanzado o un update y solo para el Codex que se acaba de reabrir con esa conversación.
- **«This conversation is open in another app … press R»** justo tras reabrir: su servidor de fondo
  compartido tarda unos segundos en soltar al cliente cerrado. Se pulsa **«r»** (nunca «fork» ni salir),
  a los 3 s de verlo y luego cada 4 s, como mucho 4 veces, y solo para ese mismo Codex. Si de verdad
  está abierta en otra app, no cambia nada y acaba en `necesita_usuario`.
- Lo contestado va al resultado en `answered` (`codex_update_skip`, `codex_retry_open_elsewhere`;
  `claude_trust_folder` para la confianza de carpeta de Claude) y al diario (`relaunch.dialog_answered`).
- Cualquier otro diálogo sigue siendo `necesita_usuario`.

### Resultado por objetivo (añadidos)
`version`, `model`, `effort` (lo que dice la barra de estado tras reabrir, si se puede leer),
`background_saved`, `message_sent` y `draft_restored`. Ejemplo en `apply-update-response.json`.

### Anuncio
Cuando lo implementa, un equipo añade a `capabilities` `relaunch.v1.update` y
`relaunch.v1.update.claude.<tipo>` por cada tipo de ventana donde lo hace. También
`relaunch.v1.restaura` si guarda monitores y borradores. La fila de `capacidades` de
`proveedores.json` la cambia cada equipo en el mismo commit que su prueba en vivo.

### Mac y SSH
Para un objetivo SSH, el Mac **ejecuta por SSH el mismo trabajador de Linux**
(`linux/uniconnect/relaunch_worker.py`, empaquetado en la app), como ya decía la sección 2 del
documento. No mantiene una segunda implementación. El «Actualizar Claude» antiguo del Mac
(`Packages/UniConnectClaudeUpdate`) pasa a ser este verbo.

Lo que hace el Mac (10-11):
- Empaqueta en la app `relaunch_worker.py`, `resume_catalog.py`, `agent_identity_hook.py`,
  `linux/scripts/recovery.py` y `mensajes.json`, y arma la petición exactamente como
  `RelaunchAgents.request` (test de paridad en `RelaunchWorkerParityTests`, que ejecuta el cliente de
  Python): el trabajador comprimido con zlib en `python3 -c`, `messages` en el `start` de Claude,
  `options` siempre en `agent.update`, `updated_to`, la acción `update` con el `launcher` de
  `proof.installation`, y plazos de 40 s (`inspect`/`start` de Claude) y 300 s (`update`).
- La prueba del `inspect` se devuelve tal cual en `expected`; la clave del objetivo es la del
  contrato (`ssh:user@host:port|tmux:<socket>|pane:%N|gen:<generación del trabajador>`).
- **Divergencia razonada, solo en ventanas locales del Mac: no hay `recreate_session`.** Matar la
  sesión tmux local cerraría la ventana del escritorio que está enganchada a ella. Si
  `respawn-pane` falla, el objetivo queda `fallido` (`escalation: respawn_pane`) y no se toca nada
  más. En SSH rige el escalado completo del trabajador.
