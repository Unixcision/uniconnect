# UniConnectClaudeBridge

Domain and transport implementation for Claude Code lifecycle signals arriving
from UniConnect's direct SSH/tmux boxes. The package owns the privacy-minimized wire
contract, HMAC/freshness/replay checks, loopback listener, remote integration renderer,
route status machine, and both durable and streaming minimal session contracts used by
the updater.

The executable target supplies two dependencies:

- an encrypted `ClaudeBridgeTokenStoring` repository;
- a main-actor `ClaudeBridgeNotificationDelivering` adapter.

The package never receives an SSH command or credential. Tokens are generated remotely,
enrolled through the already-authenticated reverse SSH tunnel, retained remotely in mode
`0600`, and encrypted locally by the app adapter.

After authentication, `ClaudeBridgeService.sessionSignals` publishes an `AsyncStream` of
`ClaudeBridgeSessionSignal` values for non-polling session coordination. These values contain
only route/session IDs, cwd, tmux pane, event kind, and validated timestamp. `Stop` and
`idle_prompt` are user-visible; `SessionStart` is internal-only. `UserPromptSubmit` updates
only the private remote activity journal and never transports the prompt. The journal stores
at most a SHA-256 prompt correlation, under a per-route `0600` lock, so a delayed completion
cannot overwrite a newer `running` transition.
