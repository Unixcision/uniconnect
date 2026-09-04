# UniConnect — master-goal traceability

Source of truth: the 2026-09-03 master goal supplied for this workspace.

This document maps every major requirement to current evidence. It intentionally
does not treat old builds or manual sessions as proof for the release candidate.
Detailed execution state lives in [`UNICONNECT_PLAN.md`](UNICONNECT_PLAN.md).

Legend: **verified** = current focused check passed; **integrating** = code exists but
final integration evidence is pending; **open** = required work remains.

## 1. Work protection

Status: **verified / ongoing**

- Dirty worktree, history, processes and installed app were inspected before edits.
- Existing user changes are preserved; no reset, session kill, tmux mutation or
  intermediate app installation has been performed.
- The installed UniConnect process remains untouched until one final authorised install.
- Builds are serialized and the first integrated Debug build will use the required tag.

## 2. Independence from cmux

Status: **integrating**

- Product/executable/app and release bundle identity are UniConnect /
  `com.unixcision.uniconnect`; the command-line executable remains `cmux` by explicit
  project policy.
- Application Support, config, state, socket, relay, hooks, logs, Keychain,
  notification identifiers and temporaries use UniConnect namespaces.
- Updater/focus/startup logs and relay auth paths that still targeted cmux were corrected.
- The only intended read of cmux data is the explicit read-only migration adapter.
- A final residual scan and before/after fingerprint check of cmux-owned files remains open.

## 3. Empty state, persistence and restoration

Status: **integrating**

- No-workspace launch uses a non-persisted first-run surface rather than a real shell.
- Recovery-relevant box/window changes request an immediate coherent save; periodic save
  remains a safety net.
- Local windows retain name, cwd, agent kind, session history, startup policy and state.
- Missing roots and failed agent launch remain recoverable rather than deleting a window.
- The adversarial pass found ownership races for pending/reopened sessions; fixes and
  behaviour tests are open before acceptance.

## 4. CONNECT.md source of truth

Status: **integrating**

- Markdown parser/planner handles boxes, LOCAL/SSH, connection blocks, tables, cwd,
  agent resume commands, tmux and formatting variation.
- Preview is immutable and sanitised, with creates, updates, unchanged, conflicts,
  rejects, duplicates and selectable actions.
- Apply uses checkpoint + private journal + persist/reread verification + exact rollback.
- SSH commands are structurally validated; secrets do not enter display identities.
- Starter-document consistency and changed-endpoint respawn defects found in review are
  being fixed. A dry preview of the real source copy remains open.

## 5. Robust SSH/tmux reconnect

Status: **integrating**

- Automatic, selected-window and global forced reconnection paths share the same action.
- Restore/reconnect requires an existing tmux and never creates a replacement or detaches
  another client. Explicit new-window creation is the sole create path.
- Re-entry guards prevent programmatic selection churn from recursively reconnecting.
- Open work: stable single-flight lifetime, canonical endpoint+tmux ownership, local cwd
  safety and comprehensive behavioural tests.
- Latest shortcut decision: `⌘R` refreshes the focused SSH/tmux window immediately;
  `⌃⌘R` refreshes all. Local/browser contexts retain their own valid behaviour.

## 6. Update Claude

Status: **integrating**

- Local and remote targets, host grouping, safe process inspection, update state machine,
  progress, cancellation, journal and restoration paths are implemented.
- The package currently passes 23 focused tests.
- Real work sessions are never used for `/exit` or update testing.
- App-target integration tests and sacrificial local/remote E2E remain open.

## 7. Local and remote completion notifications

Status: **integrating**

- Remote integration is namespaced, merge-safe and reversible; event payloads are minimal.
- Per-installation tokens, validation, age/replay rejection and deduplication are present.
- Bridge routes survive reconnect and feed UniConnect notification/navigation state.
- The package currently passes 22 focused tests.
- Tunnel, app-closed, multi-host, permission and exact-focus E2E remain open.

## 8. Images

Status: **integrating**

- Box profile is authoritative for LOCAL versus SSH; SSH without usable vault/profile
  fails closed and never inserts a local path remotely.
- SSH upload handles connection options and keeps `sshpass` secrets out of argv.
- Real byte progress, percentage, cancellation, timeout and cleanup are implemented.
- Final all-entrypoint regression suite and integrated build validation remain open.

## 9. Sidebar and rail 2026

Status: **integrating**

- Expanded cards and compact coloured rail use separated views, immutable row snapshots
  and action bundles.
- Compact hover/focus flyout shows full name, window count, LOCAL/SSH and window choices.
- Live state badges, hover corridor, keyboard/VoiceOver, Reduce Motion and pre-macOS-26
  material fallback are represented in code and documented.
- Isolated-app visual validation in light/dark/accessibility modes remains open.

## 10. Logo and visual identity

Status: **verified in source / visual E2E open**

- Canonical input and SHA-256 provenance are documented in
  `design/UniConnect.icon/SOURCE.md`.
- A single generator derives Release, Debug, Nightly, light/dark, About and docs assets.
- The obsolete chevron and its legacy generator were removed from the working tree.
- Finder, Dock, About and running-app cache behaviour will be checked only after the final
  authorised installation.

## 11. Menus and shortcuts

Status: **integrating**

- [`docs/MENUS.md`](docs/MENUS.md) inventories ownership and intended availability.
- Shared action routes are used by main menu, contextual UI, rail/flyout and palette.
- Obsolete visible focus controls and duplicate creation routes are removed or disabled.
- Focused `⌘R` refresh migration and final menu/shortcut/state tests remain open.
- All final user-facing labels must pass the 20-locale catalogue audit.

## 12. Touch ID and security

Status: **integrating**

- Startup/manual lock uses LocalAuthentication with explicit system-password fallback and
  protected content/window levels.
- Sensitive actions require recent authentication.
- Release vault key policy is Keychain-only after a verified one-time migration.
- Signature guards reject ad-hoc update identity changes; a stable Apple Development
  identity is available.
- Final visual system-dialog ordering, signed Release and threat model remain open.

## 13. Desktop and Claude-session reorganisation

Status: **planning only, as required**

- Phase 1 is not reversed.
- `scripts/plan-desktop-phase2.py` produces a private exact metadata inventory,
  source/destination manifest, dependency/Claude-slug analysis and guarded rollback.
- [`docs/UNICONNECT-DESKTOP-PHASE2.md`](docs/UNICONNECT-DESKTOP-PHASE2.md) records the
  proposed tree and validation contract.
- No Desktop path has been moved. IMPUESTOS taxonomy and optional PongFrenetico move
  explicitly require separate user decisions.

## 14. Required documentation

Status: **integrating**

- README, core architecture, delivery, menus, bridge, updater, rail, recovery, cmux
  migration and Desktop dry-run guides exist.
- A dedicated CONNECT import guide and repository threat model remain open.
- Final pass will remove stale claims and record only results from this candidate.

## 15. Acceptance and delivery

Status: **open**

- Current focused evidence: AgentLaunch 74 tests, ClaudeBridge 22 tests and ClaudeUpdate
  23 tests pass. Project parsing/checks performed by feature owners are provisional until
  the integrated run.
- Required next gates: project normalization/wiring checks, isolated Debug build, focused
  and full tests, signed Release, sanitised CONNECT preview, sacrificial E2E, cmux
  fingerprint check, localization/secret/adversarial audits.
- `vendor/bonsplit` must be committed and pushed to its remote `main` before its parent
  pointer is committed.
- Parent commits and branch push precede the single installation-approval question.
- Final install includes one recoverable backup and checks Touch ID, state, every window,
  tmux, transcripts, rail, badges, notifications, logo and menus without touching cmux.
