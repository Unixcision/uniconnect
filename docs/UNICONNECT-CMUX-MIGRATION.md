# Manual migration from cmux

UniConnect never reads or writes cmux data during ordinary startup, restore,
autosave or shutdown. The single compatibility boundary is the explicit
**Migrate Boxes from cmux…** action. It is intentionally one-way and read-only
with respect to cmux.

## Source and scope

The action reads the cmux session snapshot at:

```text
~/Library/Application Support/cmux/session-com.cmuxterm.app.json
```

It does not open, close or signal the cmux app; modify the source snapshot;
read cmux credentials or Keychain items; attach to a remote process; or copy a
cmux socket/configuration namespace into UniConnect.

Each source workspace becomes a proposed **local** UniConnect box. This is a
deliberate safety rule: a historical terminal that happened to contain `ssh`
is not proof of an SSH-box identity and must not cause process sniffing or an
unverified connection pattern to be persisted. Terminal names, order, pinning,
working directories and safe recorded agent/session metadata are retained when
available. Non-terminal panels and executable connection material are omitted.

## Preview and authentication

Migration is a sensitive action and uses the same system authentication gate as
import/export. Reading the source produces an immutable import plan before any
UniConnect state changes. The preview identifies creates, updates, unchanged
items, conflicts, rejected rows and duplicate agent sessions without showing
terminal contents or credentials.

Selection is limited to rows that remain safe and actionable. The plan is
revalidated immediately before application so a source or live-state change
cannot turn a confirmed preview into a different mutation.

## Transaction and rollback

Before the first mutation UniConnect:

1. forces its current live session snapshot;
2. writes an encrypted checkpoint containing the pre-migration document and
   vault state;
3. writes a private, non-secret transaction journal;
4. records every planned row before and after applying it.

The result is persisted and reread for verification before the journal can be
committed. Failure, cancellation or an interrupted previous transaction causes
the exact checkpoint to be restored and verified. A failed migration therefore
cannot leave a half-created set of boxes or mark its source as successfully
applied.

## Duplicate sessions and missing folders

Only the first deterministic owner of an active `(agent kind, session id)` pair
may resume automatically. Later duplicates remain as ordinary shell windows
with their names and conversation history intact. This prevents an imported
copy from stealing or overwriting an already-running session.

A missing local directory is not replaced by `~`. UniConnect keeps the saved
root as recovery metadata, blocks automatic agent launch and offers a folder
reassignment flow. Choosing a replacement updates the affected windows and
immediately persists the change.

## Verification

For a non-destructive migration check:

1. Record the source snapshot's size, modification time and SHA-256.
2. Open **Migrate Boxes from cmux…** and inspect the preview.
3. Cancel once and confirm that no UniConnect box changed.
4. Run the migration with a small selected subset.
5. Recompute the source size, modification time and SHA-256; all three must be
   identical.
6. Reopen the preview. Successfully reconciled rows must be unchanged rather
   than duplicated.
7. Verify that cmux is still running with its original workspaces and that its
   socket, configuration and history timestamps are unchanged.

If any source fingerprint changes, stop and restore UniConnect from its
before-migration checkpoint. Do not attempt to repair cmux from UniConnect.
