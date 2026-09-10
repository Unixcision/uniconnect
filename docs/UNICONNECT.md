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
`AgentActivityCoordinator` composed in `AppDelegate`). Status: macOS and Linux
done on the host side; Android pending.

Host side on Linux (2026-09-09, `linux/uniconnect/activity.py` rules and
`activity_monitor.py` cycle; `mobile_rpc.py` publishes it; same states, sources,
thresholds and aggregation as macOS unless stated here):

- **Cycle.** `ActivityMonitor` runs on a 2 s GLib timer (the timer and the
  transport are injectable, so the composition is tested with fake windows).
  Local tmux windows are probed once per socket (`uniconnect-local` or the
  record's `tmuxSocket`) with
  `tmux -L <socket> list-panes -a -F '#{session_name}\t#{pane_id}\t#{pane_current_command}\t#{pane_title}\t#{window_activity}'`
  on the window's worker pool (`Window.background`), never on GTK. The result is
  kept per pane: a window resolves the pane it saved (`paneId`, the same explicit
  `%N` that `MobilePTYProcess` targets) or the only pane of its session; two
  panes and no saved id is ambiguous and answers `unknown`, never a neighbour's
  activity. SSH boxes use the same validated `Transport` (the box's vault
  credential, `-T`, batch) but every 10 s per (box, socket) key and only while
  the vault is unlocked, since every probe is a full SSH handshake
  (`ControlMaster` is off); two sockets in one box are both probed. Local windows
  without tmux read the PTY's foreground process group (`tcgetpgrp` on the VTE
  pty, `/proc/<pgid>/comm`) and VTE's window title. Probes never overlap: a key
  in flight is skipped. A failed probe or one that no longer lists the session or
  pane clears the window's command, title and `window_activity` and the window
  answers `unknown` until a later probe finds it again; a surface without a live
  process (`pid == 0`, exited, relaunched or disposed) forgets every fact at once,
  so a dead Codex with a braille title or a visible prompt never stays `working`
  or `waiting`.
- **Facts.** Output comes from VTE's `contents-changed` on every surface (also
  tmux and SSH windows); a local key press, `mobile.terminal.input` and PTY
  input from a mobile attachment mark keyboard activity so output within 250 ms
  is echo; a VTE size change, `mobile.terminal.viewport` and PTY resizes mark a
  500 ms redraw window. The PTY facts come from `MobilePTYAttachments` only
  after permission, attachment owner and parameters are validated (`on_input`
  callback, called outside the attachment lock) and `MobileRPC.pty_activity`
  hands them to the model owner through the same `schedule` (`GLib.idle_add`)
  every RPC uses, so the resolver is only ever touched on the GTK thread and no
  lock is held across it; a rejected RPC changes nothing. `#{window_activity}` only stands in when the surface has
  produced no counted output yet. The hook rule exists (`note_hook`, 120 s TTL,
  `running`/`needsInput`/`idle`) but nothing feeds it on Linux today: hooks only
  carry the native session id, so states come from command, screen, title and
  output. The screen is VTE's visible text, read with `get_text_format(TEXT)`
  where it exists (VTE ≥ 0.76 aborts `get_text` with non-null attributes under
  `fatal-criticals`) and `get_text` on older VTE, exactly as `terminal.py`
  already does; the last 12 visible rows are kept as they are, blank rows
  included, so an old prompt scrolled off cannot be recovered. It is read only
  when output has been quiet for ≥ 1 s and only when the screen may have changed:
  a screen epoch grows with every VTE output event (counted or discarded as echo
  or resize redraw), the first read needs no observed output, and without a new
  epoch the verdict is cached, so a visible permission prompt stays `waiting`
  until the agent prints again and the user's echoed answer invalidates it. A
  real VTE under `G_DEBUG=fatal-criticals` exercises this read in
  `tests/test_activity_gtk.py`. The text is inspected and dropped, never logged
  or sent.
- **Publication.** Every terminal of `mobile.workspace.list` carries
  `activity {state, source, agent, since}` (`since` as integer epoch seconds, `0`
  before the first evaluation) and every workspace `activity {state}`; a host
  without the monitor answers `unknown`. A state or agent change refreshes the
  sidebar and calls `MobileDesktop.workspace_changed`, which now emits
  `workspace.updated` at most once per second (first change immediate, later
  ones coalesced into one trailing event). Windows whose surface disappears are
  forgotten and read back as `unknown`.
- **UI.** The workspace card and each row of the window flyout show a
  `Gtk.Spinner` while `working` and an amber `dialog-question-symbolic`
  (`uc-activity-waiting`, same amber as the Mac's raised hand) while `waiting`;
  nothing for `idle` or `unknown`. The snapshot the sidebar reconciles includes
  the state, so rows re-render only when it changes.

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

Host side on Linux (2026-09-09): the only notice source today is VTE's `bell`
(`WindowNotifications.notify_window`), which has no hook kind, so every notice
takes the fallback from the window's activity at that instant
(`activity.notification_kind`: `waiting` → `attention`, `idle` → `finished`,
else `info`) and persists it in `notificationHistory` through
`notification_record(..., kind=)`. `mobile.notifications.list` and
`notification.created` carry it; records saved before the field existed are read
back as `info` without being rewritten. The hook mapping (`kind_from_hook`) and
the `title|subtitle|body|kind` split (`split_notify_payload`) are implemented and
tested for the day a `notify` control command or agent hooks reach the Linux host.

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
`remote`, or `path` when `location` is `host` and the window's box is known to be
local. A host copy for an SSH window (`location: "host"` with `remote_error`) or for
a window whose box kind is unknown is never pasted: the sheet shows why and offers
"Copiar ruta del equipo". The route (host or fallback) and the window are captured
when a picker button is tapped, as saved state that survives a process death; a
result that returns without its capture or for another window is dropped and the
reader is asked to pick again, never re-routed with newer values. If the host stops
advertising `file_put.v1` while the picker is open, the attachment fails with its
own message and is not sent elsewhere. Pasting appends
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
  standard input and a remote POSIX `sh` script that does `mkdir -p ~/uniconnect-entrada`,
  writes `.<name>.<nonce>.part`, then links it (`ln`, which fails if the target exists)
  to `<name>`, `<name>-2`, … and prints the final path; this is the scp step of the
  contract done over the same connection. Any existing entry (file, directory or link,
  dangling ones included) counts as a collision and moves to the next suffix, so a
  directory named like the file never swallows it; at most 50 candidates are tried
  (exit 75 "sin nombre libre"); any other failure (permissions, disk, path) aborts
  with exit 74 and the reason on stderr; the temporary file is removed on every exit
  path (`trap`). The copy is bounded by a 100 s deadline (the phone waits 120 s for
  `commit`); a timeout or a non-zero exit answers `location: "host"` with
  `remote_error` (the stderr text) and the host file is always kept: there is no
  deletion policy for the host copy.
- **Threading and expiry.** All file I/O and the SSH hop run inside the actor, never
  on the main thread; the transfer table lives there too. A transfer with no chunk
  for 10 minutes is deleted together with its `.part` (injected clock, cancellable
  task). `abort` deletes the `.part` immediately.

Host side on Linux (2026-09-09, `linux/uniconnect/file_put.py`, routed by
`mobile_rpc.py`; the same paths, limits and codes as macOS unless stated here):

- **Binding.** The owner of a transfer is the approved tailnet address of the live
  connection (`MobileHost.peer_of`), never the TCP connection: the phone opens one
  connection per transfer and aborts from a fresh one after a failure, so a new
  connection from the same approved device can continue or abort, while another
  device, an unknown connection or a revoked one answers `not_found`. `begin` also
  captures the box id, kind and `credentialId` (each edit of an SSH connection is a
  new immutable vault revision, so a different id is an edited box); chunk and commit
  re-resolve the box on the GTK thread and compare: a missing or edited box answers
  `not_found` and drops the `.part` at once. A locked app answers `locked` to all four
  RPCs; a locked vault answers `locked` to the commit of an SSH box instead of
  prompting.
- **Reservation and names.** `~/UniConnect/Entrada/<YYYYMMDD>/<name>.part`, created
  `O_EXCL` with mode 0600 and day directory 0700; the final name is the first free
  ordinal not reserved by another live transfer. `commit` verifies the SHA-256,
  `fsync`s, hard-links the `.part` to the first free name (`link` fails on an existing
  file, so nothing is ever replaced) and unlinks the `.part`. `sanitize_name` keeps
  the last path component, drops control characters, replaces everything that is not
  a letter, digit, mark, space or one of `. _ - + , @ =` with `_`, strips leading dots
  and spaces, keeps a final `.ext` of up to 15 alphanumerics, and bounds the result to
  120 characters and 200 UTF-8 bytes; an empty result becomes `archivo`. `begin` also
  refuses with `io_failed` when the disk has less than the file size plus 64 MiB free,
  and with `busy` beyond 4 live transfers per device or 16 in total.
- **SSH hop.** `RemoteInbox.copy` runs, through the box's validated `SSHCommand`
  (`Transport.run`, password only via `SSHPASS`), `mkdir -p "$HOME/uniconnect-entrada"`
  and reads the absolute directory back, then uploads with the existing SFTP client
  (`SFTPTransfer.put`): a hidden `.<nonce>-<name>.partial` created `O_EXCL`, then the
  SFTP v3 rename (link+unlink on OpenSSH, so a taken name answers `SSH_FX_FAILURE`
  instead of being replaced) to `<name>`, `<name>-2`… The name sent is the final host
  name. Preparing the directory, the transfer and the close of the sftp process
  share one monotonic budget of 100 s (`RemoteInbox.budget`, injected clock): the
  `mkdir` step gets whatever is left of it, the SFTP client gets the remainder minus
  an 8 s close margin, and an exhausted budget answers `upload_timeout` without
  starting the transfer, so the host always replies before the phone's 120 s. Any
  failure answers the host path with `location: "host"` and a Spanish
  `remote_error` (`RemoteInbox.describe`, at most 500 characters, no local paths
  or content).
- **Threading and expiry.** Chunk writes, verification and the SSH hop run on the
  peer's thread, never on GTK; only the identity/lock checks hop to the model owner.
  Expiry (10 minutes without a chunk) is enforced on every file RPC, on every peer
  disconnect and by a scheduled sweep: while any transfer is live, one daemon timer
  (`threading.Timer`, injectable) runs `expire()` every 60 s and reschedules
  itself, so an abandoned `.part` is deleted between 10 and 11 minutes after its
  last chunk even if the phone never speaks again; a new connection from the same
  approved device keeps a transfer alive by sending chunks. `FilePutStore.close()`
  (called from `MobileDesktop.close` at shutdown) cancels the timer and deletes
  every live `.part`; a locked app only refuses RPCs. `abort` deletes the `.part`
  immediately.

### Transcription (mobile contract transcribe.v1, 2026-09-09)

The phone can dictate into a terminal's composer without any cloud service and
without leaving the private connection it already uses: it records a short clip,
hands the audio to the host, and the host transcribes it locally with whisper.cpp
and answers with the text alone. A host that implements it advertises
`"capabilities": ["transcribe.v1"]` in the `mobile.workspace.list` result, next to
`box_update`, `activity.v1` and `file_put.v1`. A host that does not advertise it,
or one that answers `unsupported` because it has no engine or no model, makes the
phone fall back to its own on-device dictation; nothing is ever sent elsewhere.

- `mobile.audio.transcribe {audio, mime, language?, workspace_id?, terminal_id?}` →
  `{text, engine, seconds, took_ms}`. `audio` is the whole clip in base64 (one
  request, no chunking); `mime` is `audio/mp4`, `audio/ogg` or `audio/wav`;
  `language` is `"es"`, `"en"` or absent/null for automatic detection;
  `workspace_id` and `terminal_id` are optional context and, when sent, must still
  exist. `text` is one dictation line (no timestamps, no `[BLANK_AUDIO]` markers),
  `engine` names motor and model without host paths (`whisper.cpp/ggml-base.bin`),
  `seconds` is the measured audio duration and `took_ms` what the host spent.
- Limits: `audio` ≤ 3 MiB and ≤ 5 minutes → `too_large`. The size limit is the
  protocol's, not a policy: 3 MiB of audio is 4 MiB of base64, which leaves room
  for the JSON around it inside the 8 MiB frame (`MAX_FRAME`). A 6 MiB clip would
  be exactly 8 MiB encoded and the frame decoder would drop the request before
  anyone could answer `too_large`. The phone keeps clips short anyway: this is
  dictation, not a recording service.
- Duration is measured from the audio that actually arrived, never from what the
  MIME claims, so a long recording relabelled as a tiny WAV is refused all the
  same.
- One transcription at a time per device and two per host: whisper saturates every
  core it is given, and a machine with four of them cannot serve two dictations and
  a desktop at once. A third caller waits a few seconds for a turn and then gets
  `busy`.
- A dictation the phone abandons is stopped on the host: losing the connection or
  the device's approval kills the running converter or engine instead of letting it
  finish, and no text is returned for a call that was cancelled.
- Errors: `invalid_params` (bad base64, unknown MIME, bad language, no audio),
  `too_large`, `unsupported` (no engine, no model, or no converter for a
  compressed clip; the phone dictates locally instead), `busy` (too many jobs in
  flight), `locked` (the host is locked) and `io_failed` (the engine failed, the
  deadline was exhausted or the call was cancelled), as the rest of the mobile API.
- Deadline: the phone waits 90 s from before it sends. The host's own budget is
  75 s counted from the moment the request reaches its RPC, with the tail of it
  reserved for killing the child and cleaning up.
- Privacy: the audio is written to a private temporary file and deleted on every
  exit path, success or failure. A deletion that the filesystem refuses, and
  whatever a crash leaves behind, is retried at the next start. Neither the audio
  nor the transcript is written to any log or included in an error message.

Host side on Linux (2026-09-09, `linux/uniconnect/transcribe.py`, routed by
`mobile_rpc.py`, swept at start by `mobile_desktop.py`):

- **Engine.** whisper.cpp only, looked up once and cached: the configured binary
  (`UNICONNECT_WHISPER_BIN`, which must exist and be executable) or the first of
  `whisper-cli`, `whisper-cpp`, `main` in `PATH`. `whisper-server` is deliberately
  not used: a binary in `PATH` says nothing about a daemon listening on a port, so
  routing to it would fail at the worst moment. The model is the smallest `*.bin`
  in `$XDG_DATA_HOME/uniconnect/whisper` (`~/.local/share/uniconnect/whisper`),
  which on a machine with no GPU is the only one that answers in time; a name or
  absolute path in `UNICONNECT_WHISPER_MODEL` overrides it. Threads default to
  cores minus one, capped at 8 (the MINIPC has 4 cores and no GPU), and
  `UNICONNECT_WHISPER_THREADS` overrides that. A missing binary or model answers
  `unsupported` with the reason in Spanish; a failing or timing-out engine answers
  `io_failed` and invalidates the cache, so the next call looks again.
- **Duration and conversion.** whisper.cpp only reads PCM 16-bit mono WAV at
  16 kHz. The file's own RIFF header decides both the duration and whether it can
  skip the converter; the MIME only picks a file extension. A clip that is not a
  readable WAV is measured with `ffprobe` when it exists and converted with
  `ffmpeg` (`-ac 1 -ar 16000 -c:a pcm_s16le`), and the converted WAV is measured
  again, which is what `seconds` reports; over five minutes at any of those three
  points answers `too_large` before a second of engine time is spent. The
  conversion itself is bounded in both duration (`-t`, five minutes plus a small
  margin) and output size (`-fs`), so an hour of audio never expands onto the
  host's disk; reaching either ceiling answers `too_large` rather than quietly
  transcribing a truncated clip, and an output whose format or duration cannot be
  verified answers `io_failed`. Without `ffmpeg` a clip that is not already in
  whisper's shape answers `unsupported` and the phone dictates locally. A WAV that
  passes through unconverted needs no `ffprobe` to be safe: 3 MiB at 32000 B/s
  cannot hold more than 98 seconds.
- **Budget, jobs and threading.** Probe, conversion, transcription and cleanup
  share one monotonic budget of 75 s (`TranscriptionEngine.budget`, injected
  clock), of which the last 5 s are reserved. It is stamped by
  `TranscriptionEngine.deadline()` at the top of the RPC, before the base64 is
  decoded and before the hop to the model thread, so that time comes out of the
  same budget instead of being added after it; `took_ms` is measured from there
  too. Each child process gets what is left as its own timeout, and an exhausted
  budget answers `io_failed` without starting the next step. A device may hold one
  job and the host two
  (`max_jobs_per_owner`, `max_jobs`); the turn is taken after validation, before
  the engine runs, and released in a `finally` on every ending, cancellation and
  timeout included. The same device is refused at once (a double tap is not a
  queue); a caller that meets the host-wide limit waits at most `turn_seconds`, and
  never past the budget it still needs to transcribe, before answering `busy`. The
  device is the approved tailnet address of the live connection, as in `file_put`,
  so a second connection from the same phone does not get a second turn.
  Everything runs on the peer's thread, never on GTK; only the approval and lock
  checks (and the optional box/terminal lookup) hop to the model owner. As with
  `file.commit`, a request that takes longer than the peer's 30 s idle timeout is
  answered first and its connection is closed right after, so the phone must not
  reuse that connection for the next request.
- **Cancellation.** `mobile_rpc.py` hands the engine a `cancelled` predicate that
  reads the live connection and the device's approval, so a phone that walks away
  (or a revoked device, or the host closing) stops the work rather than paying for
  it. `SubprocessRunner` runs each child through `Popen` and waits in small slices,
  checking the deadline and that predicate on every turn; when either fires it
  signals the whole process group (`start_new_session`) with `SIGTERM` and then
  `SIGKILL`, because killing only the parent leaves grandchildren holding the pipes
  open. A cancelled call answers `io_failed` and never returns text, even when the
  engine had already produced it.
- **Privacy and crash leftovers.** Each call gets its own directory (0700) named
  `<pid>-<random>` under `$XDG_CACHE_HOME/uniconnect/transcribe`
  (`~/.cache/uniconnect/transcribe`); the clip is written with `O_EXCL|O_NOFOLLOW`
  and mode 0600 and the converted WAV is chmod-ed to 0600 too. The directory is
  removed in a `finally` on success, engine failure, timeout and cancellation
  alike, and the deletion is verified rather than assumed:
  `rmtree(ignore_errors=True)` can report success with the audio still on disk, so
  the directory is checked afterwards and retried with the permissions reopened. A
  deletion the filesystem still refuses leaves the audio there; the engine records
  that directory instead of pretending otherwise, and the next sweep retries it.
- **Ownership and the sweep.** A `finally` cannot survive a killed process, so
  `TranscriptionEngine.sweep_orphans()`, called from `MobileDesktop.__init__`,
  deletes at start the work directories that have no owner. Ownership is proved by
  a `flock` on a sibling `.uc-trabajo-<token>` file. That file is itself created
  under a name the sweep does not recognise, locked, and only then renamed into
  place, because between creating a lock and taking it there is an instant when it
  would look free; the work directory is created after that. So neither a lock nor
  a directory is ever visible under its real name without an owner, and the job
  holds the lock until it is done. Births are coordinated with the sweep through a
  shared `.uc-nacimientos` lock: a job holds it (shared) while it is being born and
  the sweep takes it (exclusive) before judging any half-born file, so the gap
  between creating a lock and taking it, where it would look free without being
  abandoned, never coincides with a sweep, and a machine suspended inside that gap
  for any length of time keeps its dictation. Neither wait is open-ended: both run
  against the deadline this call already carries and against its cancellation, and a
  lock that will not come answers `busy` without starting, so a stalled process or a
  slow sweep can cost a dictation its turn but never hang it. The sweep, for its
  part, holds the shared lock only while it decides which half-born files are
  orphans and lets go before deleting them, so it never keeps a new dictation
  waiting on its own housekeeping. Half-born files use this version's own
  `.uc-naciendo-` prefix; the older `.naciendo-` files are left untouched, since a
  previous version does not take part in this coordination and its creator may well
  be alive. The kernel releases the
  lock when the owning process dies, however it dies, so a lock that can be taken
  marks an abandoned directory. The sweep holds that lock from the check through
  the deletion, never releasing it in between, and a lock left without a work
  directory is removed the same way. Age proves nothing on its own (a suspended
  machine, a clock jump or a stuck job all leave an old directory with a live
  owner), so a directory that carries no lock at all is simply kept: while two
  versions of UniConnect can coexist, neither its age nor its name proves it was
  abandoned. The previous layout, which kept the lock inside the work directory as
  `.uc-trabajo`, is still recognised so that a job created by that version is
  respected while its owner holds it. Anything else in that folder is someone
  else's and is left alone however old it is. That, plus
  skipping the directories this instance is using, is what makes the sweep safe
  while another job or another UniConnect instance is transcribing. No log line,
  message or exception carries the audio or the text: the engine's own stderr is
  never forwarded to the phone.
- **Transcript text.** Only whisper's own non-speech markers are dropped
  (`[BLANK_AUDIO]`, `[Music]`, `[Applause]`, `[_TT_…]` and the like, matched
  against a known list). A bracketed line the reader actually dictated, such as
  `[pendiente]`, is text and survives.

Host side on macOS (2026-09-10, `Sources/Mobile/MobileTranscription*.swift`, routed by
`TerminalController.mobileHostHandleRPC`):

- **Engine.** whisper.cpp through `whisper-cli`, one process per dictation, looked
  up in the Homebrew and system directories because the app does not inherit the
  user's `PATH`; `whisper-cpp` and the older `main` are accepted under the same
  role. `whisper-server` is deliberately not used, for the same reason as on Linux
  and for one more that is specific to it: the server never announces that it is
  listening. Its startup line stays in a block-buffered stdout when no terminal is
  attached and nothing equivalent reaches stderr, so a host would have to poll the
  port to find out, which the repository's concurrency rules forbid. It would buy
  about a second: on the Apple silicon machine this was measured on, `whisper-cli`
  answers a twelve-second clip in 1.57 s including the model load, against 654 MB
  the server would hold resident between dictations. The model is the first `*.bin`
  in `~/Library/Application Support/UniConnect/whisper`, chosen by a fixed
  preference (`large-v3-turbo` first, plain `large` last) so the answer does not
  depend on the order the filesystem returns; nothing is ever downloaded. A missing
  binary or model answers `unsupported` with the reason in Spanish, and
  `transcribe.v1` is then not advertised at all: `mobile.workspace.list` adds the
  capability only when both are present, so the phone dictates locally instead of
  discovering the gap mid-sentence. That check is cached for a minute, so dropping
  a model into the folder takes effect without restarting UniConnect.
- **Duration and conversion.** The clip's own RIFF header decides the duration and
  whether the converter can be skipped; the MIME only picks the temporary file's
  extension. A clip that is not a readable WAV is measured with `ffprobe` when it
  is installed and converted with `ffmpeg` (`-ac 1 -ar 16000 -c:a pcm_s16le`), and
  the converted WAV is measured again, which is what `seconds` reports. Every one
  of those measurements is checked against the five-minute limit before the next
  step runs, so an hour of audio recompressed into 3 MiB is refused before a second
  of engine time is spent. The conversion is bounded in duration (`-t`, five
  minutes plus ten seconds) and in output size (`-fs`), and a clip that comes out
  against either ceiling answers `too_large` rather than quietly transcribing half
  a dictation. Without `ffmpeg` a clip that is not already in whisper's shape
  answers `unsupported`.
- **Budget, jobs and threading.** The 75 s budget is stamped in the RPC handler
  before the base64 is decoded and before any box is looked up, so that work comes
  out of the same budget instead of being added to it, and `took_ms` is measured
  from there too. The last 5 s are reserved for killing the child and cleaning up.
  The deadline is a cancellable sleep on an injected clock racing the pipeline
  inside a task group: when it wins, the sibling is cancelled, the running child is
  killed and the call answers `io_failed`. A device may hold one dictation and the
  host two; a second request from the same phone is refused at once, because a
  double tap is not a queue. The device is the approved tailnet address of the live
  connection, as in `file_put`. Nothing runs on the main thread: the handler hops to
  an actor immediately and each dictation runs in its own detached task, so two of
  them do not take turns.
- **Cancellation.** The connection's own close path cancels that connection's
  dictations, so a phone that walks away and a device whose approval is revoked both
  stop the work rather than paying for it. Cancelling the task signals the child's
  whole process group with `SIGTERM`, and `SIGKILL` two seconds later if anything is
  still there, because killing only the parent leaves grandchildren holding the
  pipes open. That group exists because the children are not started through
  `Process`, which offers no way to open a session: `MobileTranscriptionSpawner`
  uses `posix_spawn` with `POSIX_SPAWN_SETSID`, so each child leads its own session
  and its process group carries its own pid. That is what makes `kill(-pid, …)`
  both correct and safe here; signalling a group without a session of its own would
  either reach nothing or reach UniConnect. The same spawn also closes every
  inherited descriptor (`POSIX_SPAWN_CLOEXEC_DEFAULT`), so the engine never holds a
  socket of the phone's connection. A cancelled call answers `io_failed` and never
  returns text.
- **Privacy and crash leftovers.** Each call gets its own 0700 directory named
  `<pid>-<random>` under `~/Library/Caches/UniConnect/transcribe`, and the clip is
  written with `O_EXCL|O_NOFOLLOW` and mode 0600. The directory is removed on every
  exit path, and the removal is verified rather than assumed: a `removeItem` that
  the filesystem refuses is retried with the permissions reopened. What a killed
  process leaves behind is swept at the first dictation after the next start, and
  ownership is proved by the `pid` in the name rather than by age, which proves
  nothing when a machine can be suspended mid-dictation: a directory whose owner
  still answers is kept, and so is anything whose name does not carry a `pid`,
  since two UniConnect builds can share that folder. Neither the audio nor the text
  reaches any log, and the engine's stderr is never forwarded to the phone.
- **Transcript text.** Only whisper's own non-speech markers are dropped
  (`[BLANK_AUDIO]`, `[Music]`, `[Applause]`, `[Silence]`, `[_TT_…]` and the like,
  matched against a known list). A bracketed line the user actually dictated, such
  as `[pendiente]`, is text and survives, and an unclosed bracket is text too. The
  segments whisper emits are joined into the single line the phone pastes into its
  composer.

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
