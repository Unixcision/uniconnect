# UniConnect technical architecture

UniConnect is a macOS workspace manager for durable local agent conversations and
SSH/tmux work. It is derived from cmux, but its installed product, runtime identity
and user data are independent. The bundled terminal command intentionally remains
`cmux` for command/API compatibility.

This document describes contracts, not release evidence. Current verification state
is recorded in [`UNICONNECT_PLAN.md`](../UNICONNECT_PLAN.md) and final results belong
in [`UNICONNECT-ENTREGA.md`](UNICONNECT-ENTREGA.md).

## Identity and storage boundaries

| Resource | UniConnect value |
|---|---|
| Release bundle ID | `com.unixcision.uniconnect` |
| App/product/executable | `UniConnect.app` / `UniConnect` |
| Application data | `~/Library/Application Support/UniConnect/` |
| User configuration | `~/.config/uniconnect/` |
| State, hook records, logs and recovery archive | `~/.uniconnect/` |
| Control socket | `~/.local/state/uniconnect/` |
| URL scheme | `uniconnect://` |
| Keychain services | `com.unixcision.uniconnect.*` |
| Bundled CLI command | `cmux` |

Tagged Debug and staging builds add identity-specific suffixes and use isolated state.
Normal launch, save, restore and shutdown never read or write cmux data. The only
compatibility boundary is the explicit, authenticated, read-only source action
**Migrate Boxes from cmux…**, documented in
[`UNICONNECT-CMUX-MIGRATION.md`](UNICONNECT-CMUX-MIGRATION.md).

## Durable model

A box is either LOCAL or SSH. A window belongs to one box and retains its stable
panel identity, visible name, order, selection, timestamps and runtime metadata.

LOCAL state includes:

- the workspace's default folder and an independently chosen local folder for each window;
- shell/agent/stopped runtime state;
- append-only conversation records for Claude, Codex, Agy and Grok;
- detected native session ID, agent kind, conversation-specific resume folder and last activity;
- reconstructed launch policy, never captured arbitrary argv or environment.

SSH state includes:

- opaque immutable credential revision ID;
- secret-free endpoint identity used only for ownership checks;
- exact tmux name and connection state;
- notification-bridge correlation for the stable panel.

Every recovery-relevant model change requests a save in the same main-run-loop
transaction. The eight-second tick remains a safety net; a forced periodic write
prevents an unchanged fingerprint from suppressing durable checkpoints indefinitely.
Snapshot writes use a private temporary file, `fsync`, atomic rename and directory
`fsync`, with directories mode `0700` and files mode `0600`.

## Local window lifecycle

Every user-facing **New Terminal / New Window** entry point uses the same creation
flow for the selected box, including the keyboard shortcut, tab plus button,
command palette and context menus. LOCAL opens the local-window chooser; SSH keeps
the visible-name and tmux-session dialog instead of creating a local shell.

The local chooser offers Terminal, Claude, Codex, Agy, Grok and a custom command,
with a visible name and editable **Window Folder**. The folder initially uses the
workspace default, but may be any existing local directory selected with an
absolute path or the folder picker; it need not be inside the workspace's default
folder. Choosing it changes only the new window, not the workspace default or
other windows. Name and folder are saved with the window's durable identity.

Agent launches use that window's selected folder. Claude and Agy use their required
dangerous-permission switch, while Codex uses `--yolo`; resume syntax comes from the
shared agent-launch policy. Each saved conversation retains its own resume folder,
so switching agents or changing the current shell directory does not silently
redirect an older conversation to a different project.

Running `/exit` in an agent returns to the same shell. Exiting the shell marks the
window stopped but does not discard its conversation history or box. From the shared
window action menu the user can resume a known conversation, start a fresh agent,
switch agent or keep a normal terminal.

Only one live or pending owner may claim an `(agent kind, native session ID)` pair.
Duplicate imports/restores remain named, persisted shell windows with manual resume
available. UUID-like IDs compare canonically; opaque provider IDs retain the case
semantics of their provider.

If a required saved folder disappears, UniConnect does not silently run an agent
under a different project. Recovery retains the saved conversation and explains
the missing path; selecting a replacement must not rewrite other windows' folders.

### ローカルウインドウの作成と保存

ショートカット、タブの追加ボタン、コマンドパレット、コンテキストメニューの
「新規ターミナル／新規ウインドウ」は、同じ作成フローを使用します。LOCALでは名前と
フォルダー、Terminal・Claude・Codex・Agy・Grok・カスタムコマンドを選択します。
SSHでは表示名とtmuxセッションを指定し、ローカルシェルは作成しません。
フォルダーの初期値はワークスペースのデフォルトですが、絶対パスまたはフォルダー選択で
Mac上の任意の既存フォルダーに変更できます。他のウインドウやワークスペースの
デフォルトフォルダーは変更されません。名前とフォルダーはウインドウの永続IDと共に保存されます。
ClaudeとAgyは所定の権限スキップオプション、Codexは`--yolo`を使用します。
各会話には固有の再開用フォルダーを保持するため、エージェントや現在の作業フォルダーを
変更しても、過去の会話を別のプロジェクトで再開しません。必要なフォルダーがない場合も
保存済みの会話を保持し、他のウインドウのフォルダーを変更せずに復旧します。

## SSH and tmux lifecycle

Connection material is read from the encrypted vault only when required. Validation
accepts an effective `ssh` command or `sshpass` that really invokes `ssh`; it rejects
shell chaining, pipes, substitutions and arbitrary payloads. Passwords are never
copied into previews, snapshots, logs or argv for file transfer.

Remote operations distinguish creation, recovery and strict attachment:

- explicit new-window creation may run `tmux new-session -A` for its chosen name;
- normal startup, saved-snapshot reconstruction (including archive recovery and
  history reopen), reconnect and credential-revision respawn first look for the
  exact saved tmux name. If it has disappeared, they recreate that same name and
  attach automatically, without detaching any other client;
- explicit existing-only imports still require their remote preflight to find
  the saved session. A missing session fails that check; recovery does not bypass
  it. If the session disappears after a successful preflight, subsequent snapshot
  reconstruction follows the recovery rule above.

Attachment enables tmux mouse support and a 50,000-line history limit. Canonical
ownership is based on user, host, port and tmux, not credential UUID, so two aliases
to the same destination cannot start competing clients unnoticed.

Recreating a missing tmux restores its shell, not a killed AI process or its
conversation. Resuming an AI requires the canonical saved native conversation ID
and its recorded resume folder; recovery never guesses with `--continue` or a
"latest conversation" fallback.

A forced refresh terminates only UniConnect's local foreground SSH process group and
respawns the same terminal surface in place. It preserves panel UUID, pane, ordering,
title, credential revision, bridge route and tmux. `⌘R` refreshes the focused SSH/tmux
window immediately, even before the operating system reports a timeout; `⌃⌘R`
refreshes all eligible SSH windows. Other contexts do not consume `⌘R` incorrectly.

Automatic retries use a bounded outage budget. Single-flight ownership remains held
through child readiness and a stability interval; a stale callback cannot release a
new generation. Programmatic tab selection during reconstruction never counts as a
human reconnect request.

### SSHとtmuxの再接続

通常の起動、保存済みスナップショットの再構築（アーカイブ復元と履歴からの再表示を含む）、
再接続、認証情報リビジョン変更に伴う再生成では、保存済みの正確なtmux名を
確認します。セッションが消えていれば同じ名前で自動的に再作成して接続し、他のクライアントは
切断しません。既存セッション限定のインポートでは従来どおりリモートの事前存在確認が必須で、
見つからなければその段階で失敗します。事前確認に成功した後でセッションが消えた場合、
後続のスナップショット再構築には上記の復旧ルールが適用されます。

tmuxの再作成で戻るのはシェルであり、終了したAIプロセスや会話そのものではありません。
AIの再開には保存された正規のネイティブ会話IDと会話固有の再開フォルダーが必要です。
`--continue`や「最新の会話」を使って推測しません。`⌘R`は選択中のSSHウインドウを、
`⌃⌘R`は対象の全SSHウインドウを即座に再接続します。パネルID、配置、名前、保存済みtmuxを
保持し、通常のSSHタイムアウトを待たず、`tmux kill-*`も他クライアントの切断も行いません。

## Credentials and endpoint edits

An SSH command is an immutable vault revision. Editing endpoint A to B creates a new
credential ID instead of changing the meaning of an ID referenced by current state,
recently closed items or recovery points. UniConnect preflights every live tmux on B,
then updates the box and respawns its windows transactionally. Failure restores A.

Old revisions remain available while referenced. Recovery never resolves an old ID
to newer, different connection material. Snapshot bytes and encrypted vault bytes are
captured coherently before asynchronous archive work begins.

## Backup and recovery

The readable session contains local work state and opaque credential IDs, not SSH
commands. The encrypted vault is stored separately. Automatic recovery creates at
most one point every six hours, retains seven days and caps scheduled entries at 28.
Before restore/import, UniConnect also records an explicit checkpoint.

Snapshot and vault commit or rollback together. Missing/corrupt companion vault data
cannot be reported as a successful complete backup. Detailed formats, restore rules
and operational recovery steps are in
[`UNICONNECT-RECOVERY.md`](UNICONNECT-RECOVERY.md).

## CONNECT.md import

`~/Downloads/CONNECT.md` is parsed directly as human Markdown. Preview is immutable,
side-effect-free and sanitised. Application requires a mutation lease, current-state
CAS, encrypted checkpoint, private journal, attach-only remote preflight, child
readiness and persist/reread verification. If these guarantees cannot be established,
apply fails closed while preview remains available.

See [`UNICONNECT-CONNECT-IMPORT.md`](UNICONNECT-CONNECT-IMPORT.md) for parser shapes,
reconciliation, duplicate handling and rollback invariants.

## Images

The box profile—not terminal/process sniffing—selects LOCAL versus SSH behaviour.
LOCAL uses the ordinary paste/drop path. SSH requires a valid connected profile and
uploads through the saved connection options; failure never inserts a Mac path into
the remote shell. Transfers expose actual byte percentage, progress, cancellation,
timeout and cleanup.

## Updates and notifications

Claude update orchestration is a recoverable state machine grouped by local machine or
remote host. It inspects the target, exits only identified Claude sessions, performs
one update per host, verifies versions and restores each conversation on success or
failure. Real user sessions are never update-test fixtures. Architecture:
[`UNICONNECT-CLAUDE-UPDATE.md`](UNICONNECT-CLAUDE-UPDATE.md).

The SSH completion bridge installs a namespaced, merge-safe remote hook and carries a
minimal authenticated event over a loopback-only route. Events contain correlation
metadata, not prompts or responses. The local store deduplicates notifications and
routes a click to the exact box/window. Architecture:
[`UNICONNECT-NOTIFICATION-BRIDGE.md`](UNICONNECT-NOTIFICATION-BRIDGE.md).

## Rail and menus

Expanded sidebar rows and compact rail tiles consume immutable snapshots plus action
closures, keeping observable stores above lazy-list boundaries. Compact hover/focus
opens a horizontal flyout with full box name, LOCAL/SSH, window count and individual
window choices. State, accessibility, animation and material fallbacks are documented
in [`UNICONNECT-SIDEBAR-2026.md`](UNICONNECT-SIDEBAR-2026.md).

Menu, palette, rail, title-bar and contextual entrypoints call shared actions. The
canonical inventory and shortcut table are in [`MENUS.md`](MENUS.md).

## Locking and signing

The lock surface hides app content but is ordered below the system authentication
dialog. Touch ID uses system-password fallback where LocalAuthentication requires it;
automatic locking is off by default and sensitive actions require recent auth.

Release uses a stable Apple Development identity on this Mac. Build/install scripts
compare designated requirements and reject ad-hoc or identity-changing replacement
before touching `/Applications`. Tagged Debug builds remain isolated from the Release
Keychain item and state.

## Logo provenance

The exact user-selected source, dimensions and SHA-256 are recorded in
`design/UniConnect.icon/SOURCE.md`. `scripts/generate_uniconnect_icons.py` derives every
Release/Debug/Nightly, light/dark, About and documentation size from that one canonical
asset. No legacy chevron participates in generation.

## Desktop phase 2

Desktop reorganisation is not an app side effect. Its read-only inventory, proposed
tree, path-dependency analysis and guarded rollback are documented in
[`UNICONNECT-DESKTOP-PHASE2.md`](UNICONNECT-DESKTOP-PHASE2.md). No move is authorised
by building, testing, installing or using UniConnect.
