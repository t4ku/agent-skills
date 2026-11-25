# 出典と確認範囲

確認日: 2026-11-25（Asia/Tokyo）。CLI は Orca 1.4.273。

## 公式（この日に到達を確認した URL）

| 資料 | URL |
|------|-----|
| 製品サイト | https://orca.dev/ |
| What is Orca? | https://orca.dev/docs |
| CLI overview | https://orca.dev/docs/cli/overview |
| CLI reference | https://orca.dev/docs/cli/reference |
| Orchestration | https://orca.dev/docs/cli/orchestration |
| 同内容のソース | https://github.com/stablyai/orca/blob/main/docs/site/content/docs/cli/orchestration.mdx |
| Bots quickstart | https://orca.dev/docs/bots |
| Bot security | https://orca.dev/docs/bots/security |
| Worktrees | https://orca.dev/docs/model/worktrees |
| 公式の CLI スキル（リポジトリ） | https://github.com/stablyai/orca/blob/main/skill-guides/orca-cli.md |

アプリに同梱のスキルは、インストール後に次で読む。

```sh
orca skills list
orca skills get orca-cli --full
orca skills get orchestration --full
```

1.4.273 の `orca skills list` で確認した ID: `jira-tickets`, `linear-tickets`, `orca-cli`, `orca-computer-use`, `orca-emulator`, `orca-emulator-android`, `orca-jira`, `orca-linear`, `orca-per-workspace-env`, `orca-plugin-authoring`, `orchestration`。

概要ページのインストール例: `npx skills add https://github.com/stablyai/orca --skill orca-cli`。

## 公開 Issue

| 項目 | URL | この日の状態 |
|------|-----|----------------|
| `bot work list` が終了後に空になる | https://github.com/stablyai/orca/issues/47690 | オープン（報告は 1.4.271 / 2026-11-23） |

関連して公開されているが、本スキルの手順には入れてないもの: [Issue 47691](https://github.com/stablyai/orca/issues/47691)（`bot item list --link` が `dispatch:` を直接引けない、という要望）。

## help で確認したこと（1.4.273）

- `repo add --path <path> [--kind git|folder]`。デフォルトは git。folder は通常のディレクトリや、複数 Git リポジトリの親。
- `repo hide --repo <selector>`
- `project setup-delete --setup <setup-id> [--host <host>] [--force]` と、開いているターミナルがあると拒否する旨の Notes
- `orchestration run-current [--from <handle>]`
- `orchestration send` / `check` / `worker-start` / `worker-show` / `worker-read` / `worker-list` / `ask` の存在と主要フラグ
- `terminal wait --for exit|tui-idle`
- `terminal create` はエージェント起動用ではない（`agent launch` / `worktree create --agent` を使う）
- `orchestration send --to bot:<name>` の相手はオーナーとして動く、という Notes

## 観察（この日は未再実験）

- シンボリックリンク先が既存登録だと `repo add` が旧エントリを返す
- `setup-update` でパスを変えられず、再インポートを案内されることがある
- `setup-delete --force` が、開いていた司令塔ターミナルを切り離す
- `worktree create --agent` / `agent launch` が権限スキップ系フラグを付けることがある（2026-11 中旬のホスト設定）
- Orca bot にフォルダの `mise` / `CLAUDE_CONFIG_DIR` が効かないことがある
- bot の作業場所は soul（観察では `SOUL.md`）と memory で決まる
- macOS の `security add-generic-password -w` 対話入力が 128 文字で切れる

## ドキュメントの食い違い（確認）

- CLI の登録場所: overview は Settings → General → Orca CLI、reference は Settings → Experimental → CLI。
- Orchestration は実験的機能と書かれ、実験用パネルが一時的に使えない、とも書かれている。CLI は稼働中のランタイムに話すので、先に `orca status --json` が通ること。
- `check` の既読 / ack の説明が、ドキュメント本文と 1.4.273 の help で表現が違う。実行時は公式スキルを優先する。

## このメモの範囲外

- ブラウザ自動化、エミュレータ、プラグイン作者向けの詳細（公式の `orca-cli` や各同梱スキルを読む）
- GitHub Issues を Hub から回す手順（同リポジトリの `orca-issue-orchestrator`）
- 特定ホストの ID、ハンドル、鍵、vault
