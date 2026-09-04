# Importing CONNECT.md

This document is the acceptance contract for the importer. If any transaction
guarantee below cannot be established, apply must remain disabled and only the
side-effect-free preview may be offered.

UniConnect reads the human Markdown document directly. A JSON conversion is not
part of the workflow and must not become a second source of truth.

## Supported document shape

The parser accepts the intended semantics rather than depending on one exact
rendering:

- box headings and names;
- `LOCAL` or `SSH` type labels, case-insensitively;
- fenced or indented connection commands;
- Markdown tables describing visible window names;
- local cwd values and agent resume commands;
- remote tmux names;
- surrounding notes, warnings and harmless differences in whitespace or table
  alignment.

Unknown or malformed material becomes a source-located diagnostic. It is never
silently interpreted as a shell command. An SSH connection is accepted only when
its parsed effective command is `ssh`, or `sshpass` that really invokes `ssh`.
Pipes, substitutions, redirections and command chaining are rejected.

## Preview has no side effects

Opening a document produces an immutable prepared plan before touching live state,
the vault, a remote host or tmux. The preview classifies every box and window as:

- create;
- update;
- unchanged;
- conflict;
- rejected.

Rows show their source location and proposed action. Actionable create/update rows
can be selected independently; unsafe rows cannot. Duplicated local agent sessions
and duplicated canonical SSH endpoint/tmux targets are called out before apply.
Connection commands, passwords, private-key paths and captured environment values
never appear in preview labels or diagnostics.

Cancelling preview performs no save and does not mark a seed as imported.

## Deterministic reconciliation

Reimporting the same document must be idempotent. Stable source identity and
normalised names select the same existing boxes/windows; order does not create a
second copy. An update changes the intended record rather than appending another
record with a new semantic identity.

Only one active window may own an `(agent kind, native session id)` pair. A later
duplicate keeps its visible name and conversation metadata but opens as a normal
shell with manual resume available. Likewise, one canonical
`(user, host, port, tmux)` target may have one attaching client; another record is
kept recoverable and reported instead of starting a competing attachment.

For SSH, restoration and import use this read-only remote preflight:

```text
tmux has-session -t <saved-id>
tmux set-option -t <saved-id> mouse on
tmux set-option -t <saved-id> history-limit 50000
tmux attach-session -t <saved-id>
```

The exact command is escaped by the implementation. There is no `new-session` or
detach-other-client option on an import, update, restore or reconnect path. Only an
explicitly requested new remote window may create a tmux.

## Transaction boundary

Apply revalidates the prepared plan against current state, then enters a mutation
boundary that prevents unrelated UI changes from being overwritten. Before the
first row changes, UniConnect durably records:

1. the exact app-session graph needed to restore panel UUIDs, panes, splits,
   selection and non-terminal surfaces;
2. the matching encrypted vault bytes from the same logical instant;
3. a mode-`0600`, non-secret transaction journal;
4. the source and plan fingerprints.

Each mutation is journaled before and after it runs. Remote tmux existence is
checked before mutation and the replacement SSH client must report readiness;
metadata alone is not success. Final state and vault are persisted, reread and
verified before commit.

Failure, cancellation, process interruption or a compare-and-swap conflict restores
the exact checkpoint and verifies it. Rollback preserves original panel IDs,
browser/Markdown surfaces, pane topology, selection, running shells and credential
revisions. A transaction may fail visibly; it may not leave a silent partial import.

## Credential revisions

Connection edits are immutable revisions. Changing a box from endpoint A to endpoint
B creates a new opaque credential ID rather than changing what an old ID means.
Live windows preflight their same tmux name on B and are replaced transactionally;
on failure they remain bound to A. Recently closed items and recovery points that
refer to A continue to resolve to A and can never reopen silently against B.

The readable session, preview and journal store only opaque IDs and secret-free
canonical target identity. Encrypted connection material stays in the vault.

## Safe verification with the real document

Do not test by attaching to or changing real work sessions. The delivery check is:

1. copy `~/Downloads/CONNECT.md` to a private temporary input;
2. record the source size, mtime and SHA-256;
3. parse and render a sanitized preview only;
4. confirm expected boxes, windows, duplicate decisions and rejected rows without
   printing any connection command;
5. cancel and prove UniConnect state/vault and the source fingerprint did not change;
6. run apply/reimport behaviour against isolated fixtures and sacrificial tmux names;
7. use only `tmux has-session`-style read checks for the user's known remote targets.

The final delivery report records counts and decisions, not secret commands, hosts,
addresses, usernames, key paths, prompts or transcript contents.
