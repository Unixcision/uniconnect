# UniConnect recovery and backups

UniConnect treats a box and every window inside it as durable state. Closing a
window, leaving an agent, losing the network or quitting the app must not erase
the information needed to reconstruct it.

## What is persisted

For every local window the readable session snapshot keeps:

- the box and panel identifiers, visible names, colour, order and selection;
- the workspace default folder and each window's independently selected local
  working directory, which may be outside that default folder;
- whether the runtime is a login shell, an agent or a stopped terminal;
- append-only Claude, Codex, Agy and Grok conversation records, including the
  agent kind, detected native session id, conversation-specific resume folder and timestamps;
- only a reconstructed trusted executable name and its required permission
  switch. Captured argv, API keys and captured environment variables are
  removed before persistence.

For every SSH window it keeps:

- the box and panel identifiers, names, colour, order and selection;
- an opaque credential UUID;
- the exact saved tmux name and window metadata;
- the connection reference and disconnected state needed by the UI.

The SSH command itself—including an `sshpass` password or private-key
location—exists only inside the encrypted vault. It is never copied into the
readable session JSON, recently-closed history, preview, journal or logs.

## Save triggers

`UniConnectSessionPersistenceObserver` requests a save after every
recovery-relevant model mutation: box membership/order, groups, selection,
names, colour, pinning, folder, panel membership/layout/order, profile,
credential reference, tmux binding, local-agent history and runtime or
connection state. Requests from one main-run-loop transaction are coalesced so
the saved snapshot is coherent.

An independent autosave tick runs every eight seconds. Identical fingerprints
may avoid redundant writes briefly, but a save is forced at least once per
minute. Writes use a private temporary file, `fsync`, atomic rename and a
directory `fsync`; directories are mode `0700` and files mode `0600`.

## Rolling archive

After a successful session save, `UniConnectRecoveryBackupRepository` creates
a scheduled recovery point when six hours have elapsed since the previous one:

```text
~/.uniconnect/backups/
├── session-<milliseconds>-scheduled-<uuid>.json
└── session-<milliseconds>-scheduled-<uuid>.vault.uc
```

That is four recovery opportunities per day while the app is running and able
to save. Entries older than seven days are pruned and the archive is bounded to
28 entries. The `.json` is deliberately readable local work state; the matching
`.vault.uc`, when present, remains encrypted. Debug builds use an isolated
`~/.uniconnect/debug/<bundle-id>/backups/` directory and cannot consume the
Release archive accidentally.

Before a recovery snapshot is applied, the current state is archived with the
reason `before-restore`. This makes a mistaken restore reversible too.

## Restoring an automatic point

Use **File → Restore Backup…** and choose a JSON shown from UniConnect's own
archive. The picker rejects files outside that directory, symbolic links,
damaged JSON and unsupported snapshots. After confirmation:

1. UniConnect archives the current state.
2. Missing credentials are merged from the encrypted companion vault; an
   existing current credential is never overwritten silently.
3. Recovered boxes and windows open alongside the current ones.
4. Local session claims are reconciled so one native agent session has at most
   one active owner.
5. An SSH window checks the exact saved tmux name and attaches to it. If that
   session has disappeared, snapshot reconstruction recreates the same name and
   attaches without detaching another client. A recreated shell is not a resumed
   AI conversation.

A missing required local folder does not launch an agent in an unintended
directory. Saved conversation links remain available, and choosing a replacement
for one window must not rewrite other windows or the workspace default. Each
conversation retains its own resume folder. Explicit existing-only imports still
require their remote preflight to find the saved tmux; missing sessions fail that
check. Recovery never bypasses this preflight. A session that disappears after
successful validation can be recreated during subsequent snapshot reconstruction.

## Manual backup and portable export

**Persist Now** (`⌘S`, **Guardar** in Spanish) requests a fresh asynchronous scan of
supported local agents before forcing a confirmed live-session write. Detection
is best-effort: a conversation is resumable only when its actual native session ID
is available from the supported integration. UniConnect never invents an ID,
infers one from a window name or discards previously saved conversations when a
scan finds nothing. The window name and local folder remain durable even when no
resumable AI session is detected, including ordinary shells and one-off commands.

After the confirmed session write, it writes the readable, secret-free
`backup.json` plus its authenticated encrypted credential
companion and a bounded history of matching pairs. The JSON is committed only
after its uniquely named vault companion is durable, so a crash cannot combine
state from one generation with credentials from another. Legacy whole-document
`backup.uc` files are read and migrated without deleting the original rollback
source. A failed live-session write is reported as an error, never as **Saved** or
a confirmed complete backup. This is useful before a large manual change.

### ウインドウごとのフォルダーと手動保存

各ローカルウインドウには名前と独立した作業フォルダーを保存します。ワークスペースの
デフォルトフォルダーの外も選択でき、他のウインドウやデフォルト設定は変更されません。
各会話には固有の再開用フォルダーを保持します。必要なフォルダーが存在しない場合、
意図しないプロジェクトでエージェントを起動せず、保存済みの会話を保持して復旧します。

「今すぐ保存」（`⌘S`）は対応エージェントの状態を非同期で再検出してから、セッションの
ディスク書き込み完了を確認し、機密情報を含まないJSONと暗号化された認証情報のペアを
保存します。検出はベストエフォートで、実際のネイティブセッションIDを取得できた会話
のみ再開可能です。IDを捏造したりウインドウ名から推測したりせず、検出結果がなくても
以前の会話を消しません。通常のシェルや単発コマンドも名前とフォルダーを保存します。
セッションを書き込めなかった場合はエラーを表示し、保存成功や完全なバックアップの
完了を表示しません。

Portable exports and short-lived import checkpoints intentionally remain
whole-document ciphertexts. A portable export is a passphrase-protected
transport artifact; an import checkpoint is an internal atomic rollback
capsule that must restore the document, exact session snapshot and exact vault
revision as one authenticated unit. Neither is a live/readable configuration
file.

**Export Configuration…** creates a portable `.uniconnect` container protected
by a user passphrase (PBKDF2-HMAC-SHA256 plus AES-256-GCM). Unlike the readable
automatic JSON, the exported payload can include connection material because
the whole payload is authenticated and encrypted. Wrong passphrases,
truncation and tampering are rejected before mutation.

Automatic recovery, Persist Now and portable export are complementary:

| Mechanism | Purpose | Secret handling |
|---|---|---|
| Live snapshot | Exact next-launch reconstruction | Readable state; opaque credential ids only |
| Six-hour archive | Recover accidental deletion or corruption for seven days | Readable state plus separate encrypted vault copy |
| Persist Now | User-requested local checkpoint | Readable state plus generation-bound encrypted vault companion |
| Portable export | Transfer or offline disaster recovery | Passphrase-authenticated encrypted container |

## Operational recovery checklist

If a connection hangs after changing network, use **Reconnect Now** (`⌘R`) for
the focused SSH/tmux window, or `⌃⌘R` for every eligible SSH window. UniConnect
terminates only its local SSH process group and reconstructs each panel against
the same saved tmux; it does not wait for the ordinary SSH timeout and never
sends `tmux kill-*`.

Normal startup, saved-snapshot reconstruction (including archive recovery and
history reopen), reconnect and credential-revision respawn attach to the exact
saved tmux name when it exists, or recreate that same name automatically when it
does not. They never detach another client. Explicit existing-only import
preflights remain strict and do not create a replacement during validation.

A recreated tmux restores a shell, not a killed AI process. An AI conversation
can only be resumed from its canonical saved native conversation ID and recorded
resume folder; UniConnect never substitutes `--continue` or guesses the latest
conversation. Missing identity must not be reported as a recovered AI session.

### SSH復旧時のセッションの扱い

通常の起動、保存済みスナップショットの再構築（アーカイブ復元と履歴からの再表示を含む）、
再接続、認証情報リビジョン変更による再生成では、保存済みの正確なtmux名に
接続します。既に消えている場合は同じ名前で自動的に再作成し、他のクライアントを切断しません。
一方、既存セッション限定のインポートではリモートの事前存在確認が必須で、その確認中に
セッションを作成しません。事前確認に成功した後でセッションが消えた場合は、後続の
スナップショット再構築で再作成できます。`⌘R`は選択中のSSHウインドウ、`⌃⌘R`は
対象の全SSHウインドウを即座に再接続し、通常のタイムアウトを待ったり`tmux kill-*`を実行したり
せず、パネルと保存済みtmux名を保持します。

tmuxの再作成で復旧するのはシェルで、終了したAIプロセスや会話ではありません。AIの再開には
保存された正規のネイティブ会話IDと固有の再開フォルダーが必要です。`--continue`や最新の会話の
推測で代用せず、会話IDがない状態をAIセッションの復旧成功として表示しません。

If a local agent exits, stay in the shell and use the window action menu to
resume a recorded conversation or start another agent. Do not delete the
conversation unless **Forget Conversation…** is explicitly confirmed.

If a signed update fails, the installer preserves the previous app under
`~/.uniconnect/backups/install/<timestamp>/UniConnect.app`. Restoring that
bundle also restores its stable code-signing identity; do not delete the
backup until the updated app has been checked manually.

Never repair a vault by overwriting it with an empty file. Preserve the current
session JSON, vault and install backup, then restore the last known-good signed
app or import a verified portable export.
