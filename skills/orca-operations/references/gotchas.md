# ハマりどころ（確認と観察を分ける）

確認日は 2026-11-25、CLI は Orca 1.4.273。再実験していないことは「観察」と書く。

## 退職済みコマンドと生きているコマンド

- **確認**: `orchestration run` / `run-stop` / `coordinator-start` / `coordinator-stop` は効果がなく、`orca skills get orchestration --full` を案内される（公式ドキュメント）。
- **確認**: `orchestration run-current` は 1.4.273 に残っており、「この司令塔に結びついている Run を表示する」。退職済みの `run` と混同しない。
- 推奨される開始は `run-create` + `task-create` + `worker-start`。

## `--from` を落とす

司令塔以外のシェルから `send` / `check` / `run-current` / `worker-start` などを叩くと、どの Run の話かがずれる。毎回 `--from <terminal-handle>` を付ける。ワーカーが送る `worker_done` の preamble にも、正しい `--from` が含まれる（help）。

## シンボリックリンクと `repo add`

**観察**: 新しいパスが、すでに Orca に登録した場所へのシンボリックリンクだと、`repo add` は新規ではなく既存エントリを返す。リンク先が解決されるため。

回避（観察）:

1. リンクを一時的にリネームして、リンクではない実パスにする。
2. その実パスで `orca repo add --path <abs-path> --kind folder --json` する。
3. 戻り値の id が新しいことを確かめる。
4. リンクを元に戻す。
5. 旧登録が不要なら、承認のうえ `repo hide` または `setup-delete` する。

可能なら、登録対象はリンクではなく実ディレクトリにする。

## `setup-update` ではパスが変わらないことがある

**観察**: 既存セットアップのパスを `project setup-update` で書き換えようとして、再インポートを案内された。その場合は新しいパスで登録し直し、旧セットアップを外す。

## `setup-delete` と `--force`

**確認**（1.4.273 help）: 開いているターミナルや保存済み workspace の詳細があると拒否する。`--force` はそれでも外す。

**観察**: `--force` は、その登録に結びついて開いていた司令塔ターミナルも切り離す。help の `--force` 説明文は「worktree removal」寄りの汎用文で、このコマンドの挙動と表現がずれて見える。挙動は Notes の「Refuses while the project has open terminals...; --force removes it anyway.」を信じる。

承認なしに `--force` しない。先に `hide` だけで足りるかも確認する。

## 起動時の権限スキップフラグ

**観察（2026-11 中旬、1.4.273 では未再検証）**: `worktree create --agent` と `agent launch` が、当時のホスト設定で Claude / Codex に権限スキップ系フラグを付けた。

方針としてそれらのフラグを禁止しているなら:

- Orca のエージェント起動設定を直す（根本対応）。
- 直るまでは、Codex レビューは `codex exec -s read-only`、Claude 実装は `CLAUDE_CONFIG_DIR=<profile-dir> claude -p --allowedTools <limited>` で起動する。

このスキルの手順では、スキップフラグを付けて起動しない。

## Orca bot とアカウント分離

**確認**: `orchestration send` の help は、`--to bot:<name>` の相手は **オーナーとして動く** と書いている。

**観察**: フォルダワークスペースの `mise` や `CLAUDE_CONFIG_DIR` が、Orca bot には効かないことがある。bot の作業ディレクトリは、bot フォルダの soul / memory で決まる（公式: それらはプレーンな Markdown。観察: `SOUL.md` という名前が多い）。

アカウントを分けたい作業（別の Claude プロファイルが必要な実装など）は、その設定で立ち上げた hub セッションに渡し、Orca bot に直接実装させない。

登録パスを移したあとは、bot の soul / memory の作業場所も更新し、古い司令塔を使い続けない。

## `tui-idle` は完了ではない

`terminal wait --for tui-idle` は、承認プロンプトで静かに止まった作業を拾うのに使える（観察・公式の wait 条件としても存在）。ただし idle は「入力待ち / 停止に見える」であって `worker_done` ではない。

`worker-show` で人の応答待ちと分かっているときは、その事実を優先する。

## `bot work list` が空に見える

[stablyai/orca#47690](https://github.com/stablyai/orca/issues/47690): ワーカー終了後、`orca bot work list` が何も返さない、という報告（1.4.271、2026-11-23、オープンを確認）。回避として報告されているのは `orchestration run-list` のあと、Run ごとに `worker-list`。1.4.273 では未再実験。

## macOS キーチェーンの 128 文字切れ

**観察**: `security add-generic-password -w` の対話入力は 128 文字で切れることがある。長いサービスアカウントトークンを入れるときは `read -rs` で変数に受け、`-w` に渡してすぐ `unset` する。検証は値を表示せず、長さと接頭辞、`op whoami` だけにする。

## `check` の既読の扱い

ドキュメント（orchestration ページ）は、デフォルトの `check` を未 ack の Delivery として説明し、処理後に `--ack` する流れを示している。1.4.273 の help は、デフォルトで未読バッチを処理済みにし、`--ack` は古い Orca 向け、と書いている。

運用では、動いている版の `orca skills get orchestration --full` に従う。覗くだけなら `--peek`。
