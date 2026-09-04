# Contributing to UniConnect

## Prerequisites

- macOS 14+
- Xcode 26.x (see `.xcode-version`)
- [Zig](https://ziglang.org/) (install via `brew install zig`)

## Getting Started

1. Clone the repository with submodules:
   ```bash
   git clone --recursive https://github.com/Unixcision/uniconnect.git
   cd uniconnect
   ```

2. Run the setup script:
   ```bash
   ./scripts/setup.sh
   ```

   This will:
   - Initialize git submodules (GhosttyKit, Bonsplit, and the inherited Homebrew tap)
   - Build the GhosttyKit.xcframework from source
   - Create the necessary symlinks

3. Build the debug app:
   ```bash
   ./scripts/reload.sh --tag my-feature
   ```
   The script prints the `.app` path. Cmd-click to open, or pass `--launch` to open automatically.

## Development Scripts

| Script | Description |
|--------|-------------|
| `./scripts/setup.sh` | One-time setup (submodules + xcframework) |
| `./scripts/reload.sh` | Build Debug app (pass `--launch` to also open it) |
| `./scripts/reloadp.sh` | Build and launch Release app |
| `./scripts/reload2.sh` | Reload both Debug and Release |
| `./scripts/rebuild.sh` | Clean rebuild |

## Rebuilding GhosttyKit

If you make changes to the ghostty submodule, rebuild the xcframework:

```bash
cd ghostty
zig build -Demit-xcframework=true -Doptimize=ReleaseFast
```

## Running Tests

### macOS tests

```bash
./scripts/reload.sh --tag contributor-check
xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/cmux-contributor-check test
```

Never launch an untagged Debug build: tagged builds have an isolated app identity, socket, and derived-data directory.

### UI tests

```bash
xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/cmux-contributor-ui \
  -only-testing:cmuxUITests test
```

## Ghostty Submodule

The `ghostty` submodule points to [manaflow-ai/ghostty](https://github.com/manaflow-ai/ghostty), a fork of the upstream Ghostty project.

### Making changes to Ghostty

Do not commit an unreachable submodule pointer. Push a Ghostty change to a fork controlled by the contributor, verify that the commit is reachable from that fork's permanent branch, update `.gitmodules` when necessary, and only then update the parent gitlink. Never push a UniConnect contribution directly to a Manaflow remote.

See `docs/ghostty-fork.md` for details on fork changes and conflict notes.

## License

Contributions submitted to this repository are licensed under the project's GNU General Public License v3.0 or later (`GPL-3.0-or-later`). No additional commercial-license grant to Unixcision or Manaflow is required by this fork.

If you separately submit a change to the upstream cmux repository, that contribution is governed by the upstream project's terms and contribution policy.
