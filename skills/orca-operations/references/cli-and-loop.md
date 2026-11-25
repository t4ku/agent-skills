# コマンドの型（Orca 1.4.273）

フラグは変わる。実行前に `orca <command> --help` と `orca skills get orchestration --full` を見る。ここでは 2026-11-25 に help で確認した形だけを残す。

## 状態確認

```sh
orca status --json
orca worktree ps --json
orca worktree current --json
orca terminal list --worktree <selector> --json
```

## Orchestration

公式の監督付きループ（ドキュメント）:

```sh
orca orchestration run-create --objective "<objective>" --json
orca orchestration task-create --spec "<spec>" --task-title "<title>" --json
orca orchestration worker-start --task <taskId> --worktree current --agent codex --from <terminal-handle> --json
# 新しい child worktree なら:
orca orchestration worker-start --task <taskId> --worktree new-child --name <name> --agent codex --setup run --from <terminal-handle> --json
```

`--model` と `--effort` は `--terminal`（既存ペインの再利用）と両立しない。新しい worktree の `--name` は省略できる。

結びついている Run の確認:

```sh
orca orchestration run-current --from <terminal-handle> --json
```

メッセージ:

```sh
orca orchestration send \
  --from <terminal-handle> \
  --to bot:<name> \
  --type status \
  --subject "<subject>" \
  --body "<body>" \
  --json
```

`--to` の例: `bot:<name>`、`dispatch:<dispatchId>`、`run:<runId>`、グループアドレス（`@all`、`@idle`、`@codex` など）。`worker_done` と heartbeat はグループ宛てにできない。長い本文は `--body-file`。

受信:

```sh
# 既読にせず中を見る
orca orchestration check --from <terminal-handle> --peek --json
# 特定タイプを待つ（公式ドキュメントの例）
orca orchestration check --wait --types worker_done,escalation,question --timeout-ms 900000 --json
```

1.4.273 の help: デフォルトの `check` は、結びついた Run の最古の未読バッチを返し、処理済みにする。`--peek` / `--all` は既読にしない。`--wait` 中は 15 秒ごとに stderr へ keepalive の JSON が出る。

ワーカー完了（ワーカー側。公式どおり task と dispatch の両方を付ける）:

```sh
orca orchestration send \
  --type worker_done \
  --subject "<short subject>" \
  --body "<what changed, what remains>" \
  --task-id <taskId> \
  --dispatch-id <dispatchId> \
  --outcome succeeded \
  --json
```

質問（ワーカー → コーディネーター）:

```sh
orca orchestration ask \
  --question "<question>" \
  --options "option-a,option-b" \
  --timeout-ms 600000 \
  --json
```

`--json` なら `.answer` を machine-readable に取れる（公式）。

検査と後始末:

```sh
orca orchestration worker-list --json
orca orchestration worker-show --dispatch <dispatchId> --json
orca orchestration worker-read --dispatch <dispatchId> --limit 50 --json
orca orchestration worker-stop --dispatch <dispatchId> --json
orca orchestration worker-release --dispatch <dispatchId> --json
```

`worker-start --retry-of <dispatchId>` は配置を継承しない。`--on` / `--worktree` と `--agent` / `--terminal` を改めて渡す。

低レベルな配役（公式）: worktree を作り、`terminal wait --for tui-idle` のあと `orchestration dispatch --task <taskId> --to <workerHandle> --inject`。

## ターミナル

```sh
orca terminal create --worktree id:<repoId>::<worktreePath> --title "<title>" --json
orca terminal wait --terminal <handle> --for tui-idle --timeout-ms 300000 --json
orca terminal wait --terminal <handle> --for exit --timeout-ms 60000 --json
orca terminal send --terminal <handle> --text "<text>" --enter --json
orca terminal read --terminal <handle> --json
```

`--for` は `exit` または `tui-idle`（1.4.273）。エージェントを新しく始めるなら `agent launch` または `worktree create --agent` を使い、`terminal create --command` では始めない。

## Worktree / Repo / Project

```sh
orca worktree create --repo id:<repoId> --name <name> --json
orca repo list --json
orca repo add --path <abs-path> --kind folder --json
orca repo show --repo id:<repoId> --json
orca repo hide --repo <selector> --json
orca project setups --json
orca project setup-existing-folder --project <id> --host local --path <abs-path> --kind folder --json
orca project setup-delete --setup <setup-id> --host local --json
```

`setup-delete` に `--force` を付けるのは、開いているターミナルごと外してよいと利用者が認めたときだけ。
