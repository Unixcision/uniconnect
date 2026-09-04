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

- trusted box root and window cwd;
- shell/agent/stopped runtime state;
- append-only conversation records for Claude, Codex, Agy and Grok;
- native session ID, agent kind and last activity;
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

**New Window** offers Terminal, Claude, Codex, Agy, Grok and a custom command. Agent
launches always trust the box root chosen by the user. Claude and Agy use their
required dangerous-permission switch, while Codex uses `--yolo`; resume syntax comes
from the shared agent-launch policy.

Running `/exit` in an agent returns to the same shell. Exiting the shell marks the
window stopped but does not discard its conversation history or box. From the shared
window action menu the user can resume a known conversation, start a fresh agent,
switch agent or keep a normal terminal.

Only one live or pending owner may claim an `(agent kind, native session ID)` pair.
Duplicate imports/restores remain named, persisted shell windows with manual resume
available. UUID-like IDs compare canonically; opaque provider IDs retain the case
semantics of their provider.

If a saved local root disappears, UniConnect does not silently run an agent under a
different project. It opens a safe recoverable shell, explains the missing path and
offers reassignment. The new root is persisted immediately across every affected
record.

## SSH and tmux lifecycle

Connection material is read from the encrypted vault only when required. Validation
accepts an effective `ssh` command or `sshpass` that really invokes `ssh`; it rejects
shell chaining, pipes, substitutions and arbitrary payloads. Passwords are never
copied into previews, snapshots, logs or argv for file transfer.

There are two deliberately different remote operations:

- explicit new-window creation may run `tmux new-session -A` for its chosen name;
- restore, history reopen, import and reconnect first run `tmux has-session` and then
  `tmux attach-session` against the saved name.

The second path cannot create an empty replacement and never detaches another client.
Attachment enables tmux mouse support and a 50,000-line history limit. Canonical
ownership is based on user, host, port and tmux, not credential UUID, so two aliases
to the same destination cannot start competing clients unnoticed.

A forced refresh terminates only UniConnect's local foreground SSH process group and
respawns the same terminal surface in place. It preserves panel UUID, pane, ordering,
title, credential revision, bridge route and tmux. `⌘R` refreshes the focused SSH/tmux
window immediately, even before the operating system reports a timeout; `⌃⌘R`
refreshes all eligible SSH windows. Other contexts do not consume `⌘R` incorrectly.

Automatic retries use a bounded outage budget. Single-flight ownership remains held
through child readiness and a stability interval; a stale callback cannot release a
new generation. Programmatic tab selection during reconstruction never counts as a
human reconnect request.

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
