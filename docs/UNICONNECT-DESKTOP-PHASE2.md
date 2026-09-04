# Desktop phase 2 planning

Desktop phase 2 is deliberately outside UniConnect's application migration.
It must never run as a build, install, launch, import, or recovery side effect.

## Proposed layout

Subject to a separate approval, the current top-level development directories
would move beneath `~/Desktop/DESARROLLO/`:

```text
~/Desktop/
├── DESARROLLO/
│   ├── 2DS.DEV/
│   ├── 3XA/
│   ├── NOTBETTING/
│   ├── PROYECTOS/
│   ├── PYTHON SCRIPTS/
│   └── RASPBER/
├── IMPUESTOS/             # destination still requires a decision
└── PassCodeApp.vault      # deliberately remains here
```

`PongFrenetico` is an optional, separately approved move into the existing
`PROYECTOS/MOBILE_APPS` group. Nothing in this plan assumes that approval.

## Private exact inventory

Run the read-only planner with a new output directory under UniConnect's private
backup root:

```sh
python3 scripts/plan-desktop-phase2.py \
  --output ~/.uniconnect/backups/desktop-phase2-plan-YYYYMMDD-HHMMSS
```

The planner does not follow symlinks and never mutates a source. It creates:

- a gzip JSONL inventory with path, type, size, allocation, mode, mtime, device
  and inode for every entry;
- `manifest.json` with exact proposed source/destination pairs, existence checks,
  aggregate sizes and dependency references;
- a content-free analysis of affected Claude project slugs and known config
  references;
- a guarded `rollback.sh` that refuses to run unless its explicit confirmation
  environment value is supplied;
- a private README summarising the dry-run.

File contents are never copied into the report. In particular, the planner does
not expose `CONNECT.md`, SSH configuration, transcripts, keys or vault contents.

## Required migration transaction

If the user later approves the move, implementation must be a separate task:

1. Stop or detach affected local processes cleanly; never kill remote tmux.
2. Regenerate and verify the private inventory and free-space preconditions.
3. Back up each config file that contains an old absolute path.
4. Move one top-level directory at a time on the same filesystem.
5. Verify entry counts and metadata against the manifest after every move.
6. Copy affected `~/.claude/projects` slug directories to their new slug first;
   do not rewrite JSONL transcripts in place.
7. Update `~/.claude.json`, `CONNECT.md`, relevant `CLAUDE.md` files and any SSH
   path references through format-aware edits with their own rollback copies.
8. Update UniConnect box roots and window cwd values transactionally, then prove
   they persist and restore.
9. Keep the old Claude slug directories and the rollback bundle until every
   transcript and window has been checked.

`IMPUESTOS` has deliberately not been assigned a destination: its taxonomy is a
user decision, not something inferred by this repository. `PassCodeApp.vault`
must remain at the Desktop root while any caller still has that path hard-coded.

## Dry-run acceptance checks

- Every proposed source exists or is explicitly reported missing.
- Every proposed destination is absent; an existing destination blocks apply.
- No inventory entry is unreadable.
- Old and proposed paths are enumerated in the dependency report without
  including matching line contents.
- Live terminal cwd values and Claude project slug mappings are reviewed.
- The rollback order is the exact reverse of the proposed move order.
- No filesystem move is executed until a separate user approval is recorded.
