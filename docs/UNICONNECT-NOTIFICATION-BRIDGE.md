# Puente de notificaciones Claude por SSH

## Alcance

Las cajas SSH directas de UniConnect no usan `WorkspaceRemoteConfiguration`, por lo que el
relay del daemon remoto no cubre sus sesiones. `UniConnectClaudeBridge` implementa para
ellas un canal separado, ligado a cada ventana tmux y compuesto en `cmuxApp`, sin singletons
ni dependencias de UI dentro del paquete.

Claude Code expone oficialmente `Stop` cuando termina una respuesta y `Notification` con
matcher `idle_prompt` cuando queda esperando entrada. La integración remota añade además
`UserPromptSubmit` para marcar actividad sin transportar el prompt y `SessionStart` para
confirmar una restauración exacta. Solo `Stop` e `idle_prompt` generan avisos visibles;
`SessionStart` alimenta el stream interno y `UserPromptSubmit` actualiza exclusivamente el
journal privado remoto. No interpreta ni reenvía prompts, respuestas, transcripts ni
resultados de herramientas.

Documentación de referencia de Anthropic:

- <https://code.claude.com/docs/en/hooks-guide>
- <https://code.claude.com/docs/en/hooks>

## Flujo

1. Antes de crear el panel, UniConnect reserva su UUID y registra una ruta local inmutable:
   caja, panel, credencial lógica, host sin contraseña, nombre y sesión tmux.
2. El comando SSH recibe un reverse-forward exclusivo:
   `127.0.0.1:<puerto-remoto>:127.0.0.1:<puerto-local>`. Ambos extremos escuchan solo en
   loopback y `ExitOnForwardFailure=yes` evita una falsa conexión sin canal.
3. Sobre la misma conexión SSH se instala de forma idempotente
   `~/.uniconnect/claude-bridge/v1/notify.py`. El script crea una copia exacta y privada del
   settings previo antes del primer cambio, edita únicamente rangos JSON namespaced sin
   reformatear el resto, conserva todas las claves y handlers existentes, y añade únicamente
   las entradas UniConnect. Un settings inválido o ambiguo no se toca.
4. El host remoto genera 32 bytes aleatorios, los guarda con modo `0600` y los enrola por el
   túnel. El Mac guarda el token en `claude-bridge-vault.uc`, cifrado con la clave maestra de
   UniConnect. El token no aparece en argv, logs, snapshots ni comandos SSH.
5. Cada evento posterior lleva HMAC-SHA256. El Mac comprueba ruta, firma en tiempo constante,
   antigüedad máxima de cinco minutos, tolerancia de reloj, forma de UUID/path/pane y replay.
   El par `Stop`/`idle_prompt` de la misma sesión se coalesce aunque el segundo llegue con
   el retardo normal del aviso idle; dos `Stop` separados siguen siendo dos tareas. `SessionStart` usa la
   misma autenticación, pero nunca llega al adaptador de notificaciones.
6. La navegación se resuelve siempre con la ruta local de confianza, nunca con IDs enviados
   por el servidor. `TerminalNotificationStore` recibe la caja y el panel exactos, actualiza el
   centro interno/badge y conserva el comportamiento estándar al pulsar el aviso.

La ausencia del Mac o un fallo del túnel nunca bloquea Claude: el hook es async, usa timeouts
subsegundo y devuelve éxito aunque no pueda avisar.

## Contrato remoto mínimo

Las rutas viven bajo:

```text
~/.uniconnect/claude-bridge/v1/installations/<installation-id>/
  <route-id>.route.json
  <route-id>.token
  <route-id>.session.json
  <route-id>.session.lock
```

Todos los ficheros se escriben de forma atómica; token, ruta y sesión tienen modo `0600` y el
directorio modo `0700`. `session.json` contiene exclusivamente:

```json
{
  "version": 1,
  "route_id": "uuid",
  "session_id": "uuid-o-correlación-sha256",
  "session_kind": "uuid|correlation",
  "cwd": "/ruta/remota",
  "tmux_pane": "%7",
  "activity_state": "running|idle",
  "prompt_correlation": "sha256-opcional",
  "observed_at_ms": 2000000000000
}
```

El updater debe decodificar `ClaudeBridgeRemoteSessionRecord`, comprobar route, pane y
frescura, distinguir `running` de `idle`, y usar `resumableSessionID` solo cuando
`session_kind == "uuid"`. Una correlación
sirve para deduplicar, pero nunca autoriza `--resume` ni un fallback silencioso a
`--continue`. El decoder acepta el antiguo `updated_at_ms` como journal idle para una
migración conservadora, pero el escritor nuevo emite solo `observed_at_ms`. No se registra
executable porque el hook no puede verificarlo con suficiente certeza.
`prompt_correlation` es un hash opcional del identificador de prompt oficial, nunca del texto:
serializa las escrituras con un lock `0600` y evita que un `Stop` atrasado de un prompt anterior
reemplace el estado `running` del prompt nuevo.

En paralelo, cada evento aceptado se publica localmente sin polling mediante
`UniConnectClaudeBridgeRuntime.sessionSignals` (`AsyncStream<ClaudeBridgeSessionSignal>`).
La señal lleva solamente route ID, session ID/correlación, cwd, pane, tipo y fecha. Se emite
después de validar HMAC, frescura, replay y forma, de modo que el updater puede esperar la
sesión exacta sin leer transcripts ni observar ficheros en bucle. Incluye `session_start`
como transición interna no visible; `UserPromptSubmit` no produce tráfico local.

## Estados y reconexión

Cada ruta publica valores inmutables `inactive`, `reconnecting`, `active`, `unavailable` o
`error`. El rail recibe snapshots por panel; no observa el actor ni guarda una referencia al
servicio bajo su `ForEach`. Una reconexión reusa route UUID, puerto remoto y token, vuelve a
registrar el script y reemplaza su route file sin duplicar hooks ni avisos.

Si no llega el enrolamiento dentro del timeout acotado, el estado pasa a `unavailable` sin
polling. Firma inválida o token distinto produce `error` y jamás rota el secreto de forma
implícita.

## Retirada y rollback

`unregister` elimina exclusivamente los cuatro ficheros de su route ID. Solo cuando no queda
ninguna ruta UniConnect se retiran de `Stop`, `Notification`, `UserPromptSubmit` y
`SessionStart` únicamente los commands que coinciden exactamente con los cuatro handlers
versionados; los hooks ajenos permanecen intactos.
Si el settings no cambió mientras la integración estuvo instalada, se restaura byte por byte
desde la copia content-addressed. Si hubo ediciones del usuario, se eliminan lexicalmente solo
los handlers propios y se preservan esas ediciones.

Cerrar una ventana conserva el token local para que “Cerradas” pueda reabrirla. El borrado
definitivo de una caja ofrece ejecutar el cleanup opt-in antes de borrar su registro. El
cleanup usa un proceso SSH acotado, sin shell local y sin contraseñas en argv. Solo después de
recibir código de éxito retira los tokens locales y el elemento de “Cerradas”; si el host no
está disponible, conserva el estado necesario para reintentar y no afirma que la integración
remota haya sido retirada. “Eliminar solo localmente” queda como decisión explícita separada.
