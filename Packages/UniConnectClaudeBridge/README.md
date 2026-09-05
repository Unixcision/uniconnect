# UniConnectClaudeBridge

Domain and transport implementation for Claude Code lifecycle signals arriving
from UniConnect's direct SSH/tmux boxes. The package owns the privacy-minimized wire
contract, HMAC/freshness/replay checks, loopback listener, remote integration renderer,
route status machine, and both durable and streaming minimal session contracts used by
the updater.

The executable target supplies two dependencies:

- an encrypted `ClaudeBridgeTokenStoring` repository;
- a main-actor `ClaudeBridgeNotificationDelivering` adapter.

The package never receives an SSH command or credential. Tokens are generated remotely,
enrolled through the already-authenticated reverse SSH tunnel, retained remotely in mode
`0600`, and encrypted locally by the app adapter.

Each connection attempt receives a fresh `connection_id` and a 79-byte remote Unix socket
path containing that ID and the installation ID. The durable window/route UUID and token
remain stable. Reconnection does not depend on removing a previous socket: the SSH server,
not the client's `StreamLocalBindUnlink` setting, controls the remote listener. No new TCP
listener is requested, so `GatewayPorts` cannot publish this bridge on a network interface.
The reader accepts legacy TCP route records without a `connection_id` for migration only.

Registration uses a per-route lock. The global lifecycle lock protects shared settings and
publication, but is released during network exchanges so one slow registration cannot block
other windows' hooks. Registration has two phases: the Mac accepts enrollment, the remote
script atomically publishes its route, and a signed `hello` confirms publication. A new
connection stays `reconnecting` until that confirmation or an authenticated current-connection
event arrives. Connection IDs are authenticated and stale attempts cannot replace a live route.

Enrollment and publication confirmation use five-second socket-operation timeouts and at
most one immediate retry of the same frame when there is no response. Interactive hooks keep
their 0.75-second socket timeout. Stream-local forwarding remains optional to the terminal:
`ExitOnForwardFailure=no` preserves SSH/tmux even when the bridge is unavailable. The app never
changes server forwarding policy automatically. See the
[server policy notes](../../docs/UNICONNECT-NOTIFICATION-BRIDGE.md) for a version-specific,
administrator-approved Unix-only forwarding example.

Reclaiming a previous socket is secondary and checks its exact recorded path, owner, socket
type, `ECONNREFUSED`, and unchanged inode. It does not sweep `/tmp`, remove a live listener,
or require a second reconnect to obtain a fresh endpoint.

After authentication, `ClaudeBridgeService.sessionSignals` publishes an `AsyncStream` of
`ClaudeBridgeSessionSignal` values for non-polling session coordination. These values contain
only route/session IDs, cwd, tmux pane, event kind, and validated timestamp. `Stop` and
`idle_prompt` are user-visible; `SessionStart` is internal-only. `UserPromptSubmit` updates
only the private remote activity journal and never transports the prompt. The journal stores
at most a SHA-256 correlation for an optional opaque prompt identifier, never prompt text,
under a per-route `0600` lock. It rejects older timestamped writes and is revalidated by the
updater immediately before a lifecycle mutation.

## 接続、再接続、セッション記録（日本語）

SSH接続の試行ごとに新しい`connection_id`を生成し、インストールIDと組み合わせた
79バイトのUnixソケットパスを使用します。ウインドウの永続ルートUUIDとトークンは保持します。
前のソケットは再利用せず、再接続の成功は削除処理に依存しません。リモートリスナーを
制御するのは`sshd`であり、クライアントの`StreamLocalBindUnlink`ではありません。
TCPリスナーは新規作成せず、`GatewayPorts`によるネットワーク公開もありません。
`connection_id`を持たない旧TCPルートは移行時の読み取り互換性だけを維持します。

登録はルート単位のロックで直列化します。設定と公開を保護するグローバルロックは通信中に
保持せず、遅い接続が他のウインドウのフックを止めないようにします。Macの登録受理後に
ルートを原子的に保存し、署名付き`hello`で公開完了を確認します。現在の接続の確認または
認証済みイベントが届くまで`reconnecting`のままにし、古い接続による上書きを拒否します。

登録と公開確認のソケット操作は5秒でタイムアウトし、応答がない場合だけ同じフレームを
直ちに1回再送します。通常のフックは0.75秒です。`ExitOnForwardFailure=no`により、通知の
転送が使えなくてもSSH/tmuxを開けます。サーバー設定は自動変更しません。管理者が許可した
場合の限定設定は[サーバーポリシーの説明](../../docs/UNICONNECT-NOTIFICATION-BRIDGE.md)を
参照してください。古いソケットの回収は記録されたパス、所有者、種別、`ECONNREFUSED`、
同一inodeを確認する補助処理で、生きているリスナーや他の`/tmp`ファイルは削除しません。

トークンはリモートで生成して0600で保存し、Macでは暗号化します。認証後のセッション
イベントはルート・セッションID、cwd、tmuxペイン、種類、時刻だけを通知します。
`Stop`と`idle_prompt`は表示用、`SessionStart`は内部用です。`UserPromptSubmit`はリモートの
私有記録だけを更新し、プロンプト本文を送りません。不透明なプロンプトIDの任意の相関
ハッシュは保持できますが、本文はハッシュ化しません。記録はルート別の0600ロックで保護し、
古い時刻の書き込みを拒否し、Updaterが変更する直前にも再検証します。
