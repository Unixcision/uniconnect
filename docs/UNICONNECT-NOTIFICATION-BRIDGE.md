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

Contrato de forwarding de OpenSSH (`-R` stream-local y `GatewayPorts`):

- <https://man.openbsd.org/ssh#R>
- <https://man.openbsd.org/sshd_config#GatewayPorts>

## Flujo

1. Antes de crear el panel, UniConnect reserva su UUID y registra una ruta local estable:
   caja, panel, credencial lógica, host sin contraseña, nombre y sesión tmux. Cada intento SSH
   recibe además un `connection_id` nuevo; la identidad persistente de la ventana no cambia.
2. El comando SSH solicita un reverse-forward exclusivo desde un socket Unix remoto
   `/tmp/ucb-<installation-id>-<connection-id-sin-guiones>.sock` al listener IPv4 loopback
   efímero del Mac. Conserva ambos identificadores de 128 bits y ocupa 79 bytes. Una reconexión
   no intenta reutilizar el socket anterior, aunque haya quedado huérfano. Los flags cliente
   `StreamLocalBindMask` y `StreamLocalBindUnlink` no sustituyen la política de `sshd`, que
   crea el listener remoto; no se depende de ellos para recuperar una conexión. No se crea
   ningún puerto TCP remoto nuevo y `GatewayPorts` no convierte este socket Unix en un
   listener de red. El lector conserva compatibilidad transitoria con rutas TCP antiguas
   sin `connection_id`, pero nunca crea rutas TCP nuevas.
3. Sobre la misma conexión SSH se instala de forma idempotente
   `~/.uniconnect/claude-bridge/v1/notify.py`. El script crea una copia exacta y privada del
   settings previo antes del primer cambio, edita únicamente rangos JSON namespaced sin
   reformatear el resto, conserva todas las claves y handlers existentes, y añade únicamente
   las entradas UniConnect. Un `flock` por ruta serializa sus intentos de registro. El lock
   global se limita a los cambios compartidos de settings, tokens y publicación: nunca se
   mantiene durante un intercambio de red. Un host lento no retiene así los hooks de otras
   ventanas. Un settings inválido o ambiguo no se toca.
4. El host remoto genera 32 bytes aleatorios, los guarda con modo `0600` y los enrola por el
   túnel. El Mac guarda el token en `claude-bridge-vault.uc`, cifrado con la clave maestra de
   UniConnect. La carga local exige que coincidan tanto la ruta como la revisión de credencial
   SSH actual, de modo que cambiar una caja de host obliga a un enrolamiento nuevo y el host
   anterior deja de autenticar. El token no aparece en argv, logs, snapshots ni comandos SSH.
   El alta tiene dos fases: primero el Mac acepta el enrolamiento; después el servidor publica
   atómicamente el archivo de ruta y envía un `hello` firmado. Con `connection_id`, aceptar
   únicamente el enrolamiento no pone la ruta en `active`: hace falta ese `hello` o un evento
   autenticado de la conexión actual. Un intento antiguo rechazado no reemplaza la ruta viva.
5. Cada evento posterior lleva HMAC-SHA256. El Mac comprueba ruta, firma en tiempo constante,
   antigüedad máxima de cinco minutos, tolerancia de reloj, forma de UUID/path/pane y replay.
   La firma incluye el `connection_id` cuando está presente y el receptor rechaza mensajes de
   intentos anteriores antes de cambiar el estado. Los caches de replay y correlación tienen límites globales y por ruta y fallan cerrados al
   alcanzar capacidad; el replay se conserva solo algo más que la ventana de frescura.
   El par `Stop`/`idle_prompt` de la misma sesión se coalesce aunque el segundo llegue con
   el retardo normal del aviso idle; dos `Stop` separados siguen siendo dos tareas. `SessionStart` usa la
   misma autenticación, pero nunca llega al adaptador de notificaciones.
6. La navegación se resuelve siempre con la ruta local de confianza, nunca con IDs enviados
   por el servidor. Si el panel estable cambió de workspace desde que se abrió SSH, se resuelve
   su propietario local actual y se retira el badge de estado anterior. `TerminalNotificationStore`
   recibe la caja y el panel exactos, actualiza el centro interno/badge y conserva el
   comportamiento estándar al pulsar el aviso.

La ausencia del Mac, UniConnect cerrada, un servidor sin stream-local forwarding o un fallo
del túnel nunca bloquean Claude ni impiden abrir/restaurar la terminal y su tmux:
`ExitOnForwardFailure=no`, el hook es async y devuelve éxito aunque no pueda avisar. Sus
operaciones de socket mantienen un timeout de 0,75 segundos. El enrolamiento y la confirmación
de publicación usan 5 segundos por operación y, si no reciben respuesta, como máximo un
reintento inmediato de la misma trama; no es un bucle de sondeo. La ruta queda primero
`reconnecting` y pasa a `unavailable` al vencer el plazo local de confirmación, aunque un
mensaje válido posterior puede recuperarla. Al cerrar la app desaparecen el
listener y el reverse-forward; no se promete entregar durante ese intervalo, pero el journal
remoto conserva el último estado de sesión para la siguiente reconexión.

## Contrato remoto mínimo

Las rutas viven bajo:

```text
~/.uniconnect/claude-bridge/v1/installations/<installation-id>/
  <route-id>.route.json
  <route-id>.token
  <route-id>.session.json
  <route-id>.session.lock
  <route-id>.registration.lock
```

Los documentos se escriben de forma atómica; token, ruta, sesión y locks tienen modo `0600`
y el directorio modo `0700`. `session.json` contiene exclusivamente:

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
`prompt_correlation` es un endurecimiento opcional para runtimes que aporten un identificador
opaco de prompt; nunca se calcula a partir del texto. El esquema portable oficial no garantiza
ese identificador, por lo que el escritor lo omite normalmente y no basa la restauración en él.
Las escrituras se serializan con un lock `0600`, rechazan timestamps anteriores y el updater
vuelve a verificar el journal exacto justo antes de actuar.

En paralelo, cada evento aceptado se publica localmente sin polling mediante
`UniConnectClaudeBridgeRuntime.sessionSignals` (`AsyncStream<ClaudeBridgeSessionSignal>`).
La señal lleva solamente route ID, session ID/correlación, cwd, pane, tipo y fecha. Se emite
después de validar HMAC, frescura, replay y forma, de modo que el updater puede esperar la
sesión exacta sin leer transcripts ni observar ficheros en bucle. Incluye `session_start`
como transición interna no visible; `UserPromptSubmit` no produce tráfico local.

## Estados y reconexión

Cada ruta publica valores inmutables `inactive`, `reconnecting`, `active`, `unavailable` o
`error`. El rail recibe snapshots por panel; no observa el actor ni guarda una referencia al
servicio bajo su `ForEach`. Una reconexión conserva route UUID y token, pero cambia
`connection_id` y socket remoto. Solo tras aceptar el alta se sustituye su route file sin
duplicar hooks. La retirada de un socket anterior es secundaria: se considera únicamente la
ruta exacta registrada, debe ser un socket del mismo usuario que rechace conexiones con
`ECONNREFUSED`, y su inode debe seguir coincidiendo. No se barren comodines de `/tmp` ni se
retiran sockets vivos. La primera reconexión puede funcionar sin esa limpieza.

El registro y la retirada locales se serializan por UUID de ruta. Los callbacks de salida de
Ghostty comprueban la identidad de la superficie que los originó: una salida tardía del SSH
anterior no marca como desconectada su sustituta, aunque ambas compartan el UUID del panel.

Si no llega el enrolamiento dentro del timeout acotado, el estado pasa a `unavailable` sin
polling. Firma inválida o token distinto produce `error` y jamás rota el secreto de forma
implícita.

### Política del servidor: forwarding Unix sin listeners TCP

El puente respeta las restricciones del servidor; UniConnect no edita `sshd_config`
automáticamente. En OpenSSH 9.6p1, el permiso interno de forwarding remoto también depende
de `AllowTcpForwarding`, mientras que las ACL de `PermitListen` se aplican a TCP, no a paths
Unix. Si el administrador autoriza únicamente el puente Unix para un usuario concreto, puede
validar una excepción acotada como esta, manteniendo bloqueados los túneles TCP:

```sshconfig
Match User bridge-user
    AllowTcpForwarding remote
    AllowStreamLocalForwarding remote
    PermitListen none
    PermitOpen none
Match all
```

Es un ejemplo, no una configuración que la app instale. Antes de recargar `sshd`, comprobar
la sintaxis con `sshd -t`, la configuración efectiva con `sshd -T -C` usando los extremos y
usuario reales, y que otro usuario no cambie de política. Verificar además que un forwarding
Unix funciona y uno TCP es rechazado. El resultado depende también de otros bloques `Match`,
`DisableForwarding` y las restricciones de la clave autenticada.

Referencias primarias de la versión citada:

- [Permiso compartido de forwarding en session.c](https://github.com/openssh/openssh-portable/blob/V_9_6_P1/session.c#L319-L335).
- [Separación de paths Unix y ACL de listeners TCP en channels.c](https://github.com/openssh/openssh-portable/blob/V_9_6_P1/channels.c#L3920-L3978).

## 接続と再接続（日本語）

ウインドウとtmuxの永続的なルートUUIDは維持し、SSH接続の試行ごとに新しい
`connection_id`を発行します。転送先は
`/tmp/ucb-<installation-id>-<ハイフンを除いたconnection-id>.sock`で、79バイトです。
前の接続が残したソケットを再利用しないため、孤立ソケットの削除を待たずに再接続できます。
リモートのUnixソケットを作成するのは`sshd`です。クライアント側の
`StreamLocalBindUnlink`や`StreamLocalBindMask`でサーバー設定を変更できるとは仮定しません。
新しいTCPリスナーは作成せず、`GatewayPorts`によるネットワーク公開もありません。
`connection_id`のない旧TCPルートの読み取りのみ、移行互換性として残します。

登録はルート単位のロックで直列化し、設定・トークン・ルートの公開を保護するグローバル
ロックはネットワーク通信中に保持しません。既存のClaude設定と他のフックは維持し、
壊れた設定ファイルを上書きしません。Macが登録を受理した後、サーバーはルートファイルを
原子的に保存し、署名付き`hello`を送ります。新しい接続は登録の受理だけでは`active`にせず、
この確認または現在の接続に属する認証済みイベントを必要とします。HMACには
`connection_id`も含め、古い接続のメッセージによる状態変更やルートの上書きを拒否します。

フックのソケット操作は0.75秒、登録と公開確認は5秒のタイムアウトを使います。
応答がない場合の登録・確認の再試行は同一フレームを直ちに1回だけ送り、ポーリングしません。
`ExitOnForwardFailure=no`により、通知用転送が禁止されてもSSH/tmuxは開けます。
確認期限を超えると`unavailable`になり、その後の有効な確認で復旧できます。
古いソケットの回収は補助処理で、記録された正確なパス、所有者、`ECONNREFUSED`、
同じinodeを確認します。生きているソケットや`/tmp`の他のファイルを削除しません。
古いGhosttyサーフェスの終了通知も、同じパネルUUIDを持つ新しいサーフェスには適用しません。

アプリは`sshd_config`を自動変更しません。上の`bridge-user`の例は管理者が許可した場合だけ
使う、OpenSSH 9.6p1向けの限定設定です。`AllowTcpForwarding remote`はUnix転送も必要とする
内部許可を有効化し、`PermitListen none`でTCPリスナーを禁止します。`sshd -t`と実際の接続条件を
指定した`sshd -T -C`を確認し、他ユーザーの設定を維持したうえで、Unix転送の成功とTCP転送の
拒否を検証します。`Match`の順序、`DisableForwarding`、認証キーの制限にも依存します。

トークンはリモートで生成し、0600で保存し、Mac側では暗号化します。イベントはルートと
接続ID、セッションID、cwd、tmuxペイン、種類、時刻に限定し、プロンプトや応答を送信しません。
任意の不透明なプロンプトIDの相関ハッシュだけを使用し、本文からは計算しません。
セッション記録は0600のルート別ロックで保護し、古い時刻の書き込みを拒否します。
Updaterは変更の直前にも記録を再確認します。
明示的な削除では対象ルートの設定・トークン・セッション・セッションロック・ソケットだけを
削除し、待機中のプロセス間で排他制御が分裂しないよう登録ロックのinodeは保持します。

## Retirada y rollback

`unregister` elimina exclusivamente los archivos de ruta, token y sesión de su route ID,
su lock de sesión y el socket registrado. El lock de registro por ruta se conserva para no
dividir la exclusión mutua entre procesos que estén esperando. Solo cuando no queda
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
