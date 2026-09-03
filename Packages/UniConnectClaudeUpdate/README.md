# UniConnectClaudeUpdate

`UniConnectClaudeUpdate` owns the safe, testable state machine for updating Claude Code
sessions. It has no AppKit, terminal, SSH, filesystem, credential-vault, or process-runner
dependency. The UniConnect executable supplies those capabilities through constructor-injected
protocols.

The package enforces four safety boundaries:

1. A target must pass an exact Claude/session/cwd/executable preflight before `/exit` is requested.
2. A durable recovery record is written before the exit request.
3. The update command runs once per host identity and is successful only when its exit status and
   before/after versions agree with recognized output.
4. Every target for which recovery was armed is restored and verified on success, failure, or
   cancellation. A record is removed only after the expected UUID is observed again.

## Integration

Construct `ClaudeUpdateOrchestrator` at the app composition root. Adapters should implement
`ClaudeUpdateTargetProviding`, `ClaudeSessionControlling`, `ClaudeBinaryUpdating`,
`ClaudeUpdateJournaling`, `ClaudeUpdateClock`, and `ClaudeUpdateLogging`. Calling `start(scope:)`
returns a `ClaudeUpdateOperation`; consume its `progress` stream and await `result()`.

Session adapters must use signals supplied by the terminal/process layer for idle, exit, shell, and
resume verification. They must not poll or sleep. `restore(_:)` must be idempotent: if the expected
UUID is still live, it succeeds without launching a duplicate.

Tests instantiate the orchestrator with an actor that conforms to all boundary protocols. This
lets them control suspension points, cancel immediately after `/exit`, and assert both journal and
restore behavior without launching AppKit, touching disk, or executing Claude.
