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

**Two-step box creation.** *New box* never spawns a plain terminal on its own. The
first sheet asks for the box (name, folder or SSH connection command, colour); once a
LOCAL box exists, the same local-window chooser opens immediately as a second sheet
titled *First window* so the user decides name, folder and Terminal/agent for that
window. Dismissing that second sheet opens the plain terminal the box used to get
automatically, so a box is never left without a usable window. SSH boxes keep their
welcome page, which already asks for the first window once tmux is verified. The
mobile `workspace.create` RPC accepts `initial_terminal: false` for the same two-step
flow; without the flag it keeps creating one terminal for older clients. The Linux
desktop applies the same rule: the *New workspace* dialog is followed by the
*First window* dialog, and cancelling it leaves the box empty (its existing
"create a window to start" state). Android sends `initial_terminal: false` and shows
its *Primera ventana* sheet when the host confirms an empty box.

### Favourites and order (mobile contract, 2026-09-08)

Favourites are the existing *pin*: `Workspace.isPinned` on macOS, `record["pinned"]` on
Linux. Android shows pinned workspaces and windows first within their list and keeps the
host's sidebar order for the rest. The host is the source of truth. A host that keeps
favourites and order for its clients advertises `"capabilities": ["box_update"]` in the
`mobile.workspace.list` result and implements two RPCs:

- `mobile.workspace.update {workspace_id, is_pinned?: bool, position?: int}`
- `mobile.terminal.update {workspace_id, terminal_id, is_pinned?: bool, position?: int}`

Rules: explicit values by ID (never a toggle); never change focus, selection, pane ids or
the split layout; apply `is_pinned` first, then `position`, which is zero-based *within
its group* (pinned / unpinned) and is clamped when out of range; persist as the host
already persists (autosave on macOS, `store.save` on Linux) with rollback on failure;
answer with the same full object as `mobile.workspace.list` (not the create-style filtered
snapshot); `invalid_params` when an id is missing or unknown. Unpinning leaves the item where
it sits in the host's list (physically first if it was pinned before); it does not return to
an earlier spot, because the host keeps one list and never remembers a previous position. The snapshot must also carry
`is_pinned` on every terminal, not only on workspaces. Without the capability Android
never calls these RPCs: it keeps favourites and order locally per machine and says so
once, and switches to the RPC path on its own when the host starts advertising it.
"Sync" means every client of one host sees the same; macOS and Linux are separate
installations with separate boxes and nothing is merged between them. Status: Android
done; macOS done on 2026-09-09 (`MobileBoxArrangement` holds the pure semantics; the
workspace side reuses `Workspace.isPinned`, `TabManager.setPinned` and
`reorderWorkspace(tabId:toIndex:)`; the window side reuses the existing per-panel pin
(`pinnedPanelIds`, persisted in the session snapshot and restored on relaunch) and
reorders the tab within its own pane through `applyMobileTerminalArrangement`, restoring
the previous tab selection and pane focus afterwards; the snapshot lists pinned windows
first; the tab context menu gains "Mover a la izquierda / derecha" next to the existing
"Fijar ventana"; autosave through `UniConnectCoordinator.requestSave`, with the pin rolled
back when the reorder fails); Linux done (f33dc23cc7 on `feat/linux-favorites-order`,
installed on the MINIPC and validated from the Pixel over the RPC path on 2026-09-09;
guide in `docs/LINUX-FAVORITOS.md` of that branch).

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

### Activity (mobile contract activity.v1, 2026-09-09)

The host computes, per terminal window and per workspace, whether an AI (Claude,
Codex, Gemini, Agy) is **working** or **waiting** for the user, shows it in its own
UI and publishes it to the phone. The host is the source of truth; clients never
recompute it. A host that implements it advertises `"capabilities": ["activity.v1"]`
in the `mobile.workspace.list` result (`capabilities` is an array of strings next to
`workspaces`; other capabilities such as `box_update` are added independently).

Every terminal of the snapshot carries
`"activity": {"state", "source", "agent", "since"}`:

- `state`: `working` | `waiting` | `idle` | `unknown`.
- `source`: `hooks` | `title` | `screen` | `output`, the source that decided.
- `agent`: `claude` | `codex` | `gemini` | `agy` | `null`.
- `since`: epoch seconds of the last `state` change (`0` = never evaluated).

Every workspace carries `"activity": {"state"}` aggregated over its terminals with
priority `waiting` > `working` > `idle` > `unknown`. Whenever any state changes the
host emits the existing `workspace.updated` event, coalesced to at least one second
(the macOS cycle runs every two seconds).

Rules per window (measured live on 2026-09-09):

1. **Agent** comes from the foreground command (`pane_current_command` of the local
   tmux pane, or the foreground process of the PTY: `claude`, `codex`, `gemini`,
   `agy`) or from the hooks; the title only identifies the agent (`✳` = Claude,
   braille = Codex) when the command does not. A shell (`zsh`, `bash`, `fish`, `sh`)
   means `unknown` and no indicator, whatever the title says.
2. **Hooks** already reported through `set_agent_lifecycle` (`running` → `working`,
   `needsInput` → `waiting`, `idle` → `idle`) or, failing that, the newest
   `set_status` text of the panel, win whenever the report is younger than 120 s;
   macOS keeps the report time per panel.
3. Otherwise: **(a)** a permission question visible on screen → `waiting`, beating
   everything else; **(b)** a title starting with a braille spinner (U+2800–U+28FF,
   Codex while working) → `working`; **(c)** PTY output in the last 3 s → `working`;
   **(d)** no output for more than 5 s with a live agent → `idle` (between 3 and
   5 s the previous state is kept); **(e)** else `unknown`.
4. The title is only **positive** evidence of work. Claude Code titles the window
   `✳ topic` both while working and while stopped (it changes to the topic when the
   prompt is sent and never again), so `✳` never means "stopped"; Gemini and Agy
   mark nothing.
5. The **screen** is inspected only when the output has been quiet for at least 1 s:
   the last ~12 visible lines (ANSI stripped) are matched against Claude
   "Do you want to proceed?", "❯ 1. Yes", "Esc to cancel"; Codex "Allow"/"Approve"
   with "[y/n]", "Would you like to run"; Gemini/Agy "Allow execution",
   "Apply this change". The captured text is neither logged nor sent: only the
   verdict leaves the host.
6. `since` is the epoch of the last **state change**, not of every probe.

SSH windows: the Mac cannot see the remote process and remote tmux servers keep
`set-titles` off, so the attach line (`UniConnectSSH`) applies three non-persistent
options in the same `tmux … \; …` invocation on every attach (create, existing and
recoverable paths; tmux 3.2a and 3.4+): `set-option -g set-titles on`,
`set-option -g set-titles-string '#{pane_current_command}|#{pane_title}'` and
`set-option -s set-clipboard off` (OSC 52 kills tmux 3.2a on selection). The OSC title
of an SSH surface then arrives as `command|title`; `UniConnectRemotePaneTitle` splits
it when the prefix looks like a process name: the command feeds `agent` (`claude`,
`codex`, `gemini`, `agy`; `node`/`python3` count as a live agent without a name; a
shell means `unknown`) and the braille check, and only the title part reaches the
sidebar, the tab, the window title and the phone. A title without a valid prefix
stays untouched.

Output activity comes from the PTY tee of every surface (also for tmux and SSH
windows): keyboard echo (output within 250 ms of a local or mobile key) and resize
redraws (500 ms) are not counted. Local tmux windows (socket `uniconnect-local`,
sessions `uc-<hex>`) are probed once per socket every cycle with
`tmux -L <socket> list-panes -a -F '#{session_name}\t#{pane_current_command}\t#{pane_title}\t#{window_activity}'`
off the main thread; `#{window_activity}` is only a fallback when the tee has no
data. Measured with real Claude Code: stopped, the window emits nothing (cursor
blink does not count); working, the spinner redraws continuously, so the 3 s / 5 s
thresholds hold. `waiting` only comes from hooks or screen, never from output.

macOS UI: the workspace row of the sidebar shows a small spinner while `working`
and an amber `hand.raised.fill` while `waiting`; each window's tab shows the same
through the bonsplit loading spinner and the `hand.raised.fill` icon. Nothing is
shown for `idle` or `unknown`. Implementation: `Sources/Activity/`
(`AgentActivity` value, `AgentActivityResolver` rules, `AgentActivityMonitor` actor,
`AgentActivityCoordinator` composed in `AppDelegate`). Status: macOS done; Linux
and Android pending.

#### Notification kind

Mobile notices distinguish "needs your answer" from "has finished". Every record of
`mobile.notifications.list` and every `notification.created` event carries
`"kind"`: `attention` (the agent waits for the user: permission, question,
elicitation, needs input), `finished` (turn ended: Stop, `idle_prompt`,
`agent_completed`) or `info` (everything else). The host decides it when the
notice is created and persists it with the notice; notices saved before the field
existed are read back as `info`.

Derivation: `cmux claude-hook notification` maps `notification_type`
`permission_prompt` | `elicitation_dialog` | `elicitation_url_dialog` |
`agent_needs_input` → `attention` and `idle_prompt` | `agent_completed` →
`finished`; `cmux claude-hook stop|idle` → `finished`. The generic agent hooks
(Codex, Gemini, Agy, Grok…) use the same criterion per event: `PermissionRequest`
→ `attention`, Stop / turn complete → `finished`, otherwise their classified
status (`needsInput` → `attention`, `idle` → `finished`, `error` → `info`). The
hooks send the value as an optional fourth field of the `notify*` socket payload
(`title|subtitle|body|kind`); a fourth field that is not a valid kind stays part
of the body. A notice without a hook kind (raw OSC 9/777, `cmux notify`, other
callers) falls back to the window's activity at that instant: `waiting` →
`attention`, `idle` → `finished`, `working`/`unknown` → `info`.

### File put (mobile contract file_put.v1, 2026-09-09)

The phone can hand a file to a host over the private connection it already uses,
with no external service and no SSH key on the phone: the host stores it and, when
the box is an SSH one, copies it on to the server with the same connection and
credential it already uses for that box. The phone then pastes the resulting path
into the terminal's composer so an agent can read it (Claude reads images by path).
A host that implements it advertises `"capabilities": ["file_put.v1"]` in the
`mobile.workspace.list` result, next to `box_update` and `activity.v1`. Closed on
2026-09-09 after cross review (no silent external fallback, no host path pasted into
an SSH window, transfers bound to their device and box).

RPCs, in the order one transfer uses them:

- `mobile.file.begin {workspace_id, terminal_id?, name, size, mime?}` →
  `{transfer_id, chunk_bytes}`. `chunk_bytes` ≤ 1048576 (1 MiB raw is 1.4 MiB in
  base64, under the 8 MiB frame limit). Limits: `size` ≤ 200 MiB; the host
  sanitises `name` (no paths, no odd characters). The host binds the `transfer_id`
  to the authenticated device (the mobile session's identity) and to the box and
  credential revision captured here, and reserves the final name at once (a
  `.part` file) so no other file, including a concurrent upload, is overwritten.
- `mobile.file.chunk {transfer_id, index, data}` → `{received_bytes}`. `data` is
  base64; indices are consecutive from 0. Out of order or duplicated →
  `invalid_params`. A chunk whose device, box or credential revision no longer
  match the transfer, or whose box was edited or device revoked → `not_found`.
- `mobile.file.commit {transfer_id, sha256}` → `{path, location: "host" | "remote",
  remote_path?, remote_error?}`. The same binding check as a chunk. The host
  writes to `~/UniConnect/Entrada/<YYYYMMDD>/<name>` (suffix `-2`, `-3`… if it
  exists) and verifies the SHA-256. If the box is SSH: scp to the server under a
  temporary name, then `mv` without overwriting, as `~/uniconnect-entrada/<name>`
  (creating the directory), and answer `remote_path` with `location: "remote"`;
  if the copy fails, answer the host path with `location: "host"` and a readable
  `remote_error` all the same.
- `mobile.file.abort {transfer_id}`. Transfers expire after 10 minutes without
  chunks.
- Errors: `invalid_params`, `too_large`, `not_found` (transfer, or a binding that
  changed), `io_failed`, `locked` (the host is locked), as the rest of the mobile
  API.

Phone side: a clip in the terminal's bar (real and mirror) opens a quick sheet
with "Hacer foto / Elegir imágenes / Elegir archivos" and the transfers of that
window with their progress. On commit the phone pastes into the composer only when
the file sits where the window's agent runs: `remote_path` when `location` is
`remote`, or `path` when `location` is `host` and the window's box is local. A host
copy for an SSH window (`location: "host"` with `remote_error`) is never pasted:
the sheet shows the failure and offers "Copiar ruta del equipo". Pasting appends
to what is typed, preceded by a space when something was already there, quoted if
the path carries a space. A host that does not advertise `file_put.v1` gets the
fallback the reader configured under Ajustes → "Adjuntar desde la terminal" (by
default the service of "Enviar archivos"; presets or a custom full URL with its
own style), and the fallback is never silent: the sheet shows one line above the
three buttons, "<equipo> no admite adjuntar directamente: se sube a <servicio> y
se pega el enlace", before anything is tapped, and the link is pasted instead of a
path. A `not_found` on chunk or commit (expired transfer, edited box or revoked
device) is a failure with its own message and a retry from the first byte.
Android implements the phone side; Mac and Linux implement the host side (Linux
reuses its SFTP transfer for the SSH hop, off the GTK thread).

Host side on macOS (2026-09-09, `MobileFilePutService` actor in `Sources/Mobile/`):

- **Binding.** `begin` captures the calling device (the approved tailnet address of the
  connection, which `MobileHostService` re-validates on every request and closes on
  revocation), the box id and, for SSH boxes, the credential id plus the credential
  record as resolved at that moment. Every chunk, commit and abort recomputes the
  binding from the live box and compares it: a different device, a missing box, an
  edited or unresolvable credential → `not_found`. A locked app answers `locked` to
  all four RPCs. `chunk_bytes` is 1 MiB; `size` above 200 MiB → `too_large`.
- **Reservation.** `begin` creates `~/UniConnect/Entrada/<YYYYMMDD>/<name>.part` with
  an exclusive create, choosing the first ordinal whose final name and `.part` are
  both free (`name`, `name-2`, `name-3`…), so concurrent uploads of the same name get
  distinct files. `name` is sanitised (`MobileFilePutName`: last path component only,
  no control or shell characters, no leading dot, at most 120 UTF-8 bytes, extension
  kept). Chunks append to the `.part` in order from 0 and feed an incremental SHA-256;
  a chunk beyond `size` discards the transfer with `too_large`. `commit` checks that
  the received bytes equal `size` and that the digest matches, then renames the
  `.part` to the reserved name, falling forward to the next free ordinal if a file
  appeared meanwhile; it never overwrites.
- **SSH hop.** For an SSH box the host runs the box's own validated, endpoint-pinned
  `ssh` (`UniConnectSSH.processInvocation`, same credential, `-T`) with the file on
  standard input and a remote `sh` script that does `mkdir -p ~/uniconnect-entrada`,
  writes `.<name>.<nonce>.part`, then `mv -n` to `<name>`, `<name>-2`, … until the
  temporary file is gone, and prints the final path; this is the scp step of the
  contract done over the same connection. The copy is bounded by a 100 s deadline (the
  phone waits 120 s for `commit`); a timeout or a non-zero exit answers
  `location: "host"` with `remote_error` and the host file kept.
- **Threading and expiry.** All file I/O and the SSH hop run inside the actor, never
  on the main thread; the transfer table lives there too. A transfer with no chunk
  for 10 minutes is deleted together with its `.part` (injected clock, cancellable
  task). `abort` deletes the `.part` immediately.

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
