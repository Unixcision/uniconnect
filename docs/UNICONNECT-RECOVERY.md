# UniConnect recovery and backups

UniConnect treats a box and every window inside it as durable state. Closing a
window, leaving an agent, losing the network or quitting the app must not erase
the information needed to reconstruct it.

## What is persisted

For every local window the readable session snapshot keeps:

- the box and panel identifiers, visible names, colour, order and selection;
- the trusted local box root and the window working directory;
- whether the runtime is a login shell, an agent or a stopped terminal;
- append-only Claude, Codex, Agy and Grok conversation records, including the
  agent kind, native session id and timestamps;
- only a reconstructed trusted executable name and its required permission
  switch. Captured argv, API keys and captured environment variables are
  removed before persistence.

For every SSH window it keeps:

- the box and panel identifiers, names, colour, order and selection;
- an opaque credential UUID;
- the exact saved tmux name and window metadata;
- the connection reference and disconnected state needed by the UI.

The SSH command itself—including an `sshpass` password or private-key
location—exists only inside the encrypted vault. It is never copied into the
readable session JSON, recently-closed history, preview, journal or logs.

## Save triggers

`UniConnectSessionPersistenceObserver` requests a save after every
recovery-relevant model mutation: box membership/order, groups, selection,
names, colour, pinning, folder, panel membership/layout/order, profile,
credential reference, tmux binding, local-agent history and runtime or
connection state. Requests from one main-run-loop transaction are coalesced so
the saved snapshot is coherent.

An independent autosave tick runs every eight seconds. Identical fingerprints
may avoid redundant writes briefly, but a save is forced at least once per
minute. Writes use a private temporary file, `fsync`, atomic rename and a
directory `fsync`; directories are mode `0700` and files mode `0600`.

## Rolling archive

After a successful session save, `UniConnectRecoveryBackupRepository` creates
a scheduled recovery point when six hours have elapsed since the previous one:

```text
~/.uniconnect/backups/
├── session-<milliseconds>-scheduled-<uuid>.json
└── session-<milliseconds>-scheduled-<uuid>.vault.uc
```

That is four recovery opportunities per day while the app is running and able
to save. Entries older than seven days are pruned and the archive is bounded to
28 entries. The `.json` is deliberately readable local work state; the matching
`.vault.uc`, when present, remains encrypted. Debug builds use an isolated
`~/.uniconnect/debug/<bundle-id>/backups/` directory and cannot consume the
Release archive accidentally.

Before a recovery snapshot is applied, the current state is archived with the
reason `before-restore`. This makes a mistaken restore reversible too.

## Restoring an automatic point

Use **File → Restore Backup…** and choose a JSON shown from UniConnect's own
archive. The picker rejects files outside that directory, symbolic links,
damaged JSON and unsupported snapshots. After confirmation:

1. UniConnect archives the current state.
2. Missing credentials are merged from the encrypted companion vault; an
   existing current credential is never overwritten silently.
3. Recovered boxes and windows open alongside the current ones.
4. Local session claims are reconciled so one native agent session has at most
   one active owner.
5. An SSH window performs `tmux has-session` and then `attach-session`. Recovery
   cannot create an empty replacement if the saved tmux no longer exists.

A missing local root does not launch an agent in an unintended directory. The
window opens safely and offers **Choose New Box Folder…**; reassignment updates
every affected record and saves immediately. A missing remote tmux produces a
clear stopped/disconnected state and must be resolved explicitly.

## Manual backup and portable export

**Persist Now** (`⌘S`) first forces the live session snapshot, then writes the
readable, secret-free `backup.json` plus its authenticated encrypted credential
companion and a bounded history of matching pairs. The JSON is committed only
after its uniquely named vault companion is durable, so a crash cannot combine
state from one generation with credentials from another. Legacy whole-document
`backup.uc` files are read and migrated without deleting the original rollback
source. This is useful before a large manual change.

Portable exports and short-lived import checkpoints intentionally remain
whole-document ciphertexts. A portable export is a passphrase-protected
transport artifact; an import checkpoint is an internal atomic rollback
capsule that must restore the document, exact session snapshot and exact vault
revision as one authenticated unit. Neither is a live/readable configuration
file.

**Export Configuration…** creates a portable `.uniconnect` container protected
by a user passphrase (PBKDF2-HMAC-SHA256 plus AES-256-GCM). Unlike the readable
automatic JSON, the exported payload can include connection material because
the whole payload is authenticated and encrypted. Wrong passphrases,
truncation and tampering are rejected before mutation.

Automatic recovery, Persist Now and portable export are complementary:

| Mechanism | Purpose | Secret handling |
|---|---|---|
| Live snapshot | Exact next-launch reconstruction | Readable state; opaque credential ids only |
| Six-hour archive | Recover accidental deletion or corruption for seven days | Readable state plus separate encrypted vault copy |
| Persist Now | User-requested local checkpoint | Readable state plus generation-bound encrypted vault companion |
| Portable export | Transfer or offline disaster recovery | Passphrase-authenticated encrypted container |

## Operational recovery checklist

If a connection hangs after changing network, use **Reconnect Now** (`⌘R`) for
the focused SSH/tmux window, or `⌃⌘R` for every eligible SSH window. UniConnect
terminates only its local SSH process group and reconstructs each panel against
the same saved tmux; it does not wait for the ordinary SSH timeout and never
sends `tmux kill-*`.

If a local agent exits, stay in the shell and use the window action menu to
resume a recorded conversation or start another agent. Do not delete the
conversation unless **Forget Conversation…** is explicitly confirmed.

If a signed update fails, the installer preserves the previous app under
`~/.uniconnect/backups/install/<timestamp>/UniConnect.app`. Restoring that
bundle also restores its stable code-signing identity; do not delete the
backup until the updated app has been checked manually.

Never repair a vault by overwriting it with an empty file. Preserve the current
session JSON, vault and install backup, then restore the last known-good signed
app or import a verified portable export.
