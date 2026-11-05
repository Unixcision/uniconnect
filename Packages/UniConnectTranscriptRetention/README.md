# UniConnectTranscriptRetention

Keeps the transcripts of Claude Code (`~/.claude/projects`) and Codex (`~/.codex/sessions`) within
the retention rule of `contracts/transcript-retention-v1`: every hour, a `.jsonl` untouched for
more than 30 days is compressed in place into `.jsonl.gz`, and anything untouched for more than
365 days is deleted. A conversation in use (any UniConnect window, any live AI) is never touched.
The Linux edition implements the same rule in `linux/uniconnect/transcript_retention.py`, and
both run the cases of `contracts/transcript-retention-v1/cases.json`.

- `TranscriptRetentionPlanner` is the pure rule: entries and protected ids in, a plan out.
- `TranscriptArchiver` is the actor that scans, plans and applies, never losing a line: it
  compresses to a temporary file, verifies it, gives up if the original changed meanwhile, and
  only then replaces the archive and removes the original.
- `GzipTranscriptCompressor` streams through the system's `gzip`, so a 2 GB transcript never
  sits in memory.
- `ClaudeLiveSessionReader` reads `~/.claude/sessions/<pid>.json` of live processes.

## Integration

The app composes one archiver and runs it for its lifetime:

```swift
let archiver = TranscriptArchiver(
    roots: TranscriptRoot.aiTranscripts(home: FileManager.default.homeDirectoryForCurrentUser),
    protectedConversations: { await protectedIDs() }
)
let task = Task.detached(priority: .utility) { await archiver.run() }
// task.cancel() on termination
```

## Testing

Every dependency is injected: the roots are temporary folders, `now` is a fixed date, the
protected set is a closure and `TranscriptCompressing` is a seam (the tests use the real `gzip`
and a wrapper that writes to the transcript while it is being compressed). `ClaudeLiveSessionReader`
takes its folder and an `isAlive` closure.

```sh
cd Packages/UniConnectTranscriptRetention && swift test
```
