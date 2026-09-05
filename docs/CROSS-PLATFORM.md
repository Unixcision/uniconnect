# One UniConnect, two desktop platforms

User requirement (2026-09-05): macOS and Linux belong to this repository and
evolve together, reusing as much code as possible to minimize maintenance.

## Ownership boundary

- `Packages/`: reusable domain logic and services. Extract existing portable
  functionality here before implementing another copy in a desktop adapter.
- `Resources/Localizable.xcstrings`: the canonical Spanish UI catalogue for
  both desktop editions. Linux reads this catalogue directly; do not maintain a
  second dictionary in Python. The product's Spanish-only policy is in `IDIOMA.md`.
- `Packages/CMUXAgentLaunch/Sources/CMUXAgentLaunch/Resources/agent-resume-v1.json`:
  the shared provider command syntax, consumed by Swift and the thin Linux decoder.
  Argument sanitization and existing approval choices remain in their adapters;
  sharing syntax must not silently broaden a provider's permissions.
- `docs/UNICONNECT.md` and `docs/MENUS.md`: one product contract and action inventory.
- `Sources/`: the macOS presentation/composition adapter, using SwiftUI/AppKit,
  Ghostty bindings and the system credential store.
- `linux/`: the Linux presentation/composition adapter, using GTK/VTE, Linux
  process integration and system credential storage. Its present Python domain
  implementations are transitional debt, not the desired permanent architecture.

Native interfaces need not share widget code. Session identity, provider command
syntax, reconciliation, recovery policy, wire formats and encryption envelopes
must not acquire different meanings on the two systems. Platform-specific paths,
modifier keys and secure-key providers are adapter settings, not separate product
features. No silent startup import of cmux data is permitted on either platform.

## Change workflow

1. Locate the shared contract and existing implementation in both editions.
2. Put reusable behavior in an existing portable package or a single canonical
   resource. Prefer extending a shared package to adding another runtime.
3. Connect the same behavior from both adapters. If a native bridge is required,
   keep it typed, versioned and thin; do not copy the service into the bridge.
4. Run common behavior/format fixtures and each affected platform's real build
   and behavioral tests. Linux evidence cannot stand in for a macOS build.
5. Record any intentional OS difference and any unverified platform explicitly.
   A feature is not complete on both platforms just because both menu labels exist.

Repository instructions apply this workflow to future requests by default. No
second repository, independently maintained Linux product or permanent platform
branch should be introduced. Existing development branches are ordinary temporary
work branches, not a new product line.

## Incremental convergence

The initial Linux implementation predates this clarified requirement. It consumes
the original icon, Spanish catalogue and shared agent-resume syntax and
interoperates with the original export envelope, but state/import/SSH logic is not
yet a single shared executable implementation. Be explicit about that limitation.

Converge leaf-first while preserving the working installation:

- Keep Spanish interface text and agent resume syntax single-source.
- Reuse portable agent-launch and Claude-update packages; platform process and
  filesystem services should implement their existing protocol seams.
- Extract state/import/recovery behavior only with common failure and round-trip
  fixtures so an architecture change does not weaken transactional guarantees.
- Keep local encryption providers, notifications, PTYs and desktop installation
  as OS adapters. Never replace the user's functioning installation merely to
  make the directory tree look symmetrical.

The detailed current functionality gaps remain in
[`linux/PORT_STATUS.md`](../linux/PORT_STATUS.md). Full cross-platform parity and a
fully shared core are not yet claimed.

### Transactional runtime convergence

Linux's import/endpoint adapter now stages attach-only VTE children and verifies
the exact nonce-bearing tmux client before publishing state or retiring originals.
`/proc` and VTE lifecycle handling are OS adapters; the commit/rollback policy is
not a permanent platform difference. The Python runtime coordinator remains
transitional domain code to converge with the Swift orchestration.

The current macOS SSH credential-edit transaction checks tmux existence, then
replaces terminals without equivalent attached-client proof. Import verification
waits for a non-exited Ghostty process, which is also weaker than attachment.
These are explicitly pending convergence work in `UniConnectCoordinator.swift`
and `UniConnectSSHCredentialEditTransaction.swift`, not behavior validated by
Linux tests or covered by a package-only Swift build.

The `uniconnect-shared-core.yml` workflow checks the portable launch/vault packages
on macOS and Ubuntu, and the Linux adapter suite on an isolated display. It does
not build the complete macOS application or assert full feature parity.

## Resumen

Un repositorio y un producto: los cambios se revisan para Mac y Linux. Se comparte
la lógica y los recursos, y se separa solo lo que depende del sistema. El port
actual aún tiene lógica duplicada; su convergencia es trabajo pendiente explícito.
