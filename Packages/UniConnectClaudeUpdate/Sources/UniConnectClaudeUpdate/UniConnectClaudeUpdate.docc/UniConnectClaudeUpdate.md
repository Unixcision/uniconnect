# ``UniConnectClaudeUpdate``

Safely update and restore local or SSH/tmux Claude Code sessions.

## Overview

``ClaudeUpdateOrchestrator`` is an actor-backed state machine. It resolves a
``ClaudeUpdateScope`` into immutable targets, validates a ``ClaudeUpdatePlan``, performs one
binary update per ``ClaudeUpdateHostIdentity``, and publishes immutable
``ClaudeUpdateProgress`` snapshots through `AsyncStream`.

The package never knows an SSH password, terminal object, or process implementation. Application
adapters implement the injected protocols and keep secrets outside command arguments, errors,
journal records, and ``ClaudeUpdateLogEntry`` values.

## Safety contract

Before an adapter sends `/exit`, the orchestrator saves a ``ClaudeUpdateRecoveryRecord``. Once
that record exists, restoration is an unconditional obligation. Recovery calls run in a fresh,
uncancelled task and the journal record remains until ``ClaudeSessionControlling/inspect(_:)``
observes the expected session UUID, cwd, and executable again.

Use ``ClaudeUpdateOrchestrator/recoverPendingSessions()`` during application startup before
allowing another update.

## Topics

### Running an update

- ``ClaudeUpdateOrchestrator``
- ``ClaudeUpdateOperation``
- ``ClaudeUpdateProgress``
- ``ClaudeUpdateSummary``

### Planning

- ``ClaudeUpdateScope``
- ``ClaudeUpdatePlan``
- ``ClaudeUpdateTarget``
- ``ClaudeUpdateHostPlan``

### Infrastructure seams

- ``ClaudeUpdateTargetProviding``
- ``ClaudeSessionControlling``
- ``ClaudeBinaryUpdating``
- ``ClaudeUpdateJournaling``
- ``ClaudeUpdateClock``
- ``ClaudeUpdateLogging``
