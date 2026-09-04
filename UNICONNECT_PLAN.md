# UniConnect finalisation plan

Updated: 2026-09-03

This is the live execution checklist for the current candidate. Historical builds,
tests and manual checks are not accepted as evidence for the final release.

Legend:

- `[x]` implemented and verified by a current focused check;
- `[~]` implementation exists but integration or final validation is still open;
- `[ ]` not yet completed.

## 1. Protect the running installation

- [x] Inspect branch, worktree, recent commits, build processes and installed app.
- [x] Keep the installed `/Applications/UniConnect.app` running and untouched.
- [x] Avoid destructive operations on live Claude, SSH and tmux sessions.
- [ ] Ask once for permission immediately before the single final installation.

## 2. Identity and cmux isolation

- [x] Release identity is UniConnect with bundle ID `com.unixcision.uniconnect`.
- [x] The terminal command remains `cmux` by explicit product decision.
- [x] Normal state, config, socket, relay, logs, hooks and credentials use UniConnect
  namespaces; cmux session access is isolated to explicit read-only migration.
- [~] Complete final residual-reference scan and classify legal/module/CLI references.
- [ ] Prove cmux files, sockets and process state remain byte-for-byte/timestamp stable
  during the final UniConnect E2E.

## 3. Durable local and SSH windows

- [~] Persist box/window identity, order, selection, names, colour, cwd, runtime state,
  agent conversation history, credential reference and tmux identity on every change.
- [~] Terminal, Claude, Codex, Agy, Grok and custom-command creation/switch/resume flows.
- [x] Resume argv coverage for supported agents: 74 focused package tests passed.
- [~] Missing local root opens a safe recoverable shell and offers reassignment.
- [~] Shell/agent exit retains a recoverable stopped window.
- [ ] Close ownership races for pending resumes, restored closed items and UUID
  canonicalisation; rerun behavioural tests.

## 4. SSH/tmux creation and reconnection

- [x] Restore/reconnect uses `has-session` plus `attach-session`; only explicit creation
  may use `new-session -A`; no `-D` path remains in the UniConnect flow.
- [~] Forced reconnect replaces only the local foreground SSH process and retains panel,
  box, title, credential, bridge and tmux.
- [ ] Hold single-flight ownership through the readiness/stability window.
- [ ] Canonicalise ownership by endpoint, user, port and tmux across create, restore,
  history reopen, import and reconnect.
- [ ] Prevent remote cwd values from being used as local respawn directories.
- [ ] Bind `⌘R` to focused SSH refresh, keep `⌃⌘R` global and migrate the former rename
  default without overwriting custom user bindings.
- [ ] Run all deterministic reconnection and re-entry regression tests.

## 5. Credential revision safety

- [ ] Make edits/imported endpoint changes create immutable credential revisions instead
  of rewriting an ID referenced by live windows, history or backups.
- [ ] Preflight every affected tmux on a changed endpoint and transactionally respawn all
  live windows; rollback to the old endpoint on failure.
- [ ] Capture snapshot and encrypted vault bytes coherently before asynchronous archive
  work begins.
- [ ] Test A→B edits, history reopen, vault/archive races and rollback.

## 6. CONNECT.md transactional import

- [~] Parse the human Markdown directly, including headings, connection blocks, tables,
  commands, cwd, tmux and harmless formatting variations.
- [~] Side-effect-free sanitized preview with create/update/unchanged/conflict/rejected
  rows and per-row selection.
- [~] Journaled transaction with encrypted checkpoint, persist-and-reread verification,
  cancellation and interrupted-transaction recovery.
- [~] Idempotent deterministic reconciliation and duplicate-session degradation to shell.
- [ ] Resolve starter-document mismatch and endpoint-change respawn defects found by the
  adversarial review.
- [ ] Run a sanitized preview against a copy of the actual `~/Downloads/CONNECT.md`.
- [ ] Add and verify the dedicated import guide.

## 7. Claude update and notification bridge

- [x] Claude update package: 23 focused tests passed.
- [~] Local/remote update orchestration, grouping, safe restore, progress, cancellation and
  result UI are integrated but still need app-target and sacrificial-session E2E.
- [x] Notification bridge package: 22 focused tests passed.
- [~] Authenticated, minimal, deduplicated remote completion events and namespaced hook
  merge/cleanup are integrated but still need tunnel/app-closed E2E.
- [ ] Verify notification focus routing, unread badge and reconnect status in the app.

## 8. Image transfer

- [~] LOCAL/SSH routing is driven by box profile; SSH fails closed without valid vault
  material and never inserts a Mac path as fallback.
- [~] Streaming upload exposes real byte progress, percentage, cancellation and timeout.
- [ ] Re-run all local/remote entry-point and edge-case tests on the integrated candidate.

## 9. Rail, flyout and menus

- [~] Expanded card and compact rail/flyout implementation exists with immutable row
  snapshots, badges, action bundles, keyboard/VoiceOver and Reduce Motion support.
- [~] Shared actions feed title bar, rail, flyout, main/context menus and palette.
- [~] Menu inventory and ownership are documented in `docs/MENUS.md`.
- [ ] Apply final shortcut change for focused `⌘R` refresh and rerun menu/action tests.
- [ ] Validate light, dark, accessibility contrast, live counts and hover corridor in the
  isolated Debug app.

## 10. Persistence, backups and recovery

- [~] Immediate observer-driven save plus eight-second safety tick and forced periodic
  snapshot are implemented.
- [~] Six-hour archive, seven-day retention and maximum 28 scheduled entries are present.
- [~] Pre-restore/import checkpoints, readable non-secret JSON and encrypted vault companion.
- [ ] Close snapshot/vault coherence and immutable credential revision defects.
- [ ] Verify accidental deletion restore, missing cwd, missing tmux and app-crash recovery.

## 11. Security, signing and localisation

- [x] Signing scripts reject ad-hoc identity changes; focused shell guard passed.
- [x] Stable Apple Development identity is available locally.
- [~] Current redacted secret scan findings were classified as test/env/public-client-key
  matches; rerun after final edits and record exact results.
- [~] Localisation catalogue currently covers all stable additions in 20 locale variants;
  final Coordinator/import/shortcut additions remain to be audited.
- [ ] Complete repository threat model after the required assumptions review with user.
- [ ] Build and verify one stably signed Release candidate without installing it.

## 12. Documentation and Desktop phase 2

- [~] README, architecture, menus, update, bridge, sidebar, recovery and cmux-migration
  guides are present and being reconciled with the final code.
- [~] Desktop phase 2 has a read-only exact-inventory generator and guarded rollback plan;
  no move is authorised or performed.
- [ ] Finish private Desktop inventory and record its path/checksum without publishing
  sensitive contents.
- [ ] Finalise this checklist, goal breakdown and delivery report with real evidence only.

## 13. Final validation and delivery

- [ ] Normalize/check the Xcode project and verify every new test is wired.
- [ ] Build isolated Debug with `./scripts/reload.sh --tag uniconnect-final` without launch.
- [ ] Run focused app tests, then the complete applicable test suite without concurrency.
- [ ] Build stable signed Release and dry-run signature/install guards.
- [ ] Perform final adversarial review for concurrency, secrets and data loss.
- [ ] Publish `vendor/bonsplit` commit to its remote `main`, verify ancestry, then commit its
  parent pointer.
- [ ] Create structured parent commits and push branch `uniconnect`.
- [ ] Ask for installation permission, back up once, cleanly quit, install and visually
  validate Touch ID, state, sessions, tmux, rail, badges, notifications, logo and menus.
