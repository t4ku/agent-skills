---
name: orca-operations
version: "0.1.0"
description: Orca（stablyai/orca のデスクトップ ADE）を CLI で運用するときの手順と注意点。司令塔ターミナルと毎回の --from、orchestration の完了判定、folder/git の登録、シンボリックリンク、起動フラグ、アカウント分離、秘密の値を出さない検証。公式の orca-cli / orchestration スキルを置き換えず、運用で分かった補足として使う。Use when the user asks to operate Orca, drive orchestration or worktrees, register or move a project, start a coordinator terminal, judge worker completion, or hand work to an Orca bot.
---

# Orca Operations

Orca の **運用ノート**。コマンドフラグはアプリの版で変わる。このファイルを正式なリファレンスとして固定せず、セッションの最初に公式スキルを読むこと。

同じリポジトリの `orca-issue-orchestrator` は、Hub フォルダから GitHub Issues を Worker に委譲する手順である。本スキルは、その外側の一般的な Orca 操作を扱う。

## 確認時点

- 確認日: 2026-11-25（Asia/Tokyo）
- 確認したアプリ / CLI: Orca **1.4.273**（`orca --version` と各サブコマンドの `--help`、公式ドキュメント）
- **確認**は help・公式ドキュメント・公開 Issue で裏を取ったこと。**観察**は運用で見たが、この日に再実験していないこと。推測は推測と書く。

## 1. 先に公式を読む

ランタイムに届くことを確認してから、いま動いている版のスキルを取る。

```sh
command -v orca
orca status --json
orca skills get orca-cli --full
orca skills get orchestration --full
```

公式ドキュメント（実在を確認した URL）:

- [Orca](https://orca.dev/)
- [CLI overview](https://orca.dev/docs/cli/overview)
- [CLI reference](https://orca.dev/docs/cli/reference)
- [Orchestration](https://orca.dev/docs/cli/orchestration)
- ソース側の Markdown: [orchestration.mdx](https://github.com/stablyai/orca/blob/main/docs/site/content/docs/cli/orchestration.mdx)
- [Bots](https://orca.dev/docs/bots) / [Bot security](https://orca.dev/docs/bots/security)

インストール例（overview より）: `npx skills add https://github.com/stablyai/orca --skill orca-cli`、または `orca skills install --skill orca-cli`。

1.4.273 の `orca skills list` には、少なくとも `orca-cli` と `orchestration` が含まれる。詳細な出典は [references/sources.md](references/sources.md)。

## 2. 曲げない運用ルール

- 依頼文には **対象、変更内容、受け入れ条件** の3点を書く。
- **実装とレビューは別のエージェント**にする。作った本人に完了判定をさせない（観察: 実装は Claude Code、レビューは Codex、という分担が使いやすい）。
- `--dangerously-skip-permissions` や `--dangerously-bypass-approvals-and-sandbox` など、**権限確認を飛ばすオプションは使わない**。
- ブランチの push と PR 作成はよくある範囲。**デフォルトブランチへの直接 push、マージ、デプロイ、削除**は、利用者の明示的な承認なしにしない。
- メールやチャットの外部送信、支払いも承認が要る。
- 秘密の値（トークン、鍵、パスワード）を会話・ログ・コミットに出さない。聞かない。検証は「長さと所定の接頭辞」「`op whoami` が通るか」など、**値そのものを見ない方法**で行う。

作業の台帳（作業名、worktree、ターミナル名、状態、最終要約、日時）をホスト上の決まったファイルで更新すると、別アカウントのボットとも状況を共有しやすい。置き場所と形式は、そのホストの運用に合わせる。

## 3. 司令塔ターミナルと `--from`

Orchestration は Run（名前空間とコーディネーターの受信箱）、Task、Dispatch、メッセージ、decision gate で進む。公式の推奨ループは `run-create` → `task-create` → `worker-start`。退職済みの `orchestration run` / `run-stop`（および `coordinator-start` / `coordinator-stop`）は効果がなく、公式スキルを読むよう案内される。

一方、`orca orchestration run-current` は 1.4.273 でも生きている。これは「この司令塔に結びついている Run を表示する」コマンドであり、退職済みの `run` とは別物である。

スクリプトや別ターミナルから orchestration 系コマンドを叩くときは、**毎回 `--from <terminal-handle>`** で司令塔を指定する。ハンドルは `orca terminal create ... --json` や `orca terminal list --json` の値を使い、会話やスキルに実ハンドルを書き残さない。

司令塔を新しくする例:

```sh
orca terminal create \
  --worktree id:<repoId>::<worktreePath> \
  --title "coordinator" \
  --json
orca orchestration run-current --from <terminal-handle> --json
```

セレクタは `id:<repoId>::<worktreePath>`、`path:<abs-path>`、`active` / `current` など。スクリプトでは `active` だけに頼らず、明示的なセレクタを使う。

## 4. よく使う操作

詳細なフラグは [references/cli-and-loop.md](references/cli-and-loop.md)。ここでは型だけ書く。

| 目的 | コマンド |
|------|----------|
| メッセージを送る | `orca orchestration send --from <terminal-handle> ...` |
| 受信箱を見る | `orca orchestration check --from <terminal-handle> --json`（`--peek` / `--all` は既読にしない） |
| 監督付きワーカーを始める | `orca orchestration worker-start --task <taskId> --worktree current\|new-child --agent <agent> --from <terminal-handle> --json` |
| ワーカーを見る / 出力を読む | `worker-show` / `worker-read` / `worker-list` |
| ワーカーから質問する | `orca orchestration ask --question "..." --options "a,b" --json` |
| 完了を返す | `send --type worker_done --outcome succeeded\|failed --task-id <taskId> --dispatch-id <dispatchId> ...` |
| エージェントを待たずに端末を見る | `orca terminal wait --terminal <handle> --for tui-idle --timeout-ms 300000 --json` |
| リポジトリ / フォルダを登録する | `orca repo add --path <abs-path> [--kind git\|folder] --json` |
| サイドバーから隠す | `orca repo hide --repo <selector> --json` |
| ホスト上の登録を外す | `orca project setup-delete --setup <setup-id> --host local --json`（開いているターミナルがあるときは拒否される。`--force` は承認後だけ） |

ボットへ渡すときは `orca orchestration send --to bot:<name> ...`。1.4.273 の help は、ボットが **オーナーとして動く** と書いている。

`orca bot item list` / `item show` は、承認ゲートのある環境では、許可ルールに明示されるまで確認を取ってから使う。

## 5. 完了判定

完了の権威はアクティブな Dispatch にある。判定は次の順でよい。

1. **`worker_done`**（`--outcome succeeded` または `failed` と短い要約）。報告せずにプロセスが終わった場合、Orca が失敗としてコーディネーターに知らせる（公式の説明、2026-11 時点）。
2. 質問は **`orca orchestration ask`**。ローカル TUI の確認プロンプトに置き換えない。タスクを止めるなら `blocked` と gate。
3. 承認待ちなどで **静かに止まった**ように見えるときは `orca terminal wait --for tui-idle`。tui-idle だけでは完了ではない。
4. `succeeded` の自己申告がおかしいときだけ、別の検証手段（ログ突合や外部の状態判定など）で裏を取る。常時の見張りは必須ではない。

`check` は Delivery を処理してから ack する、が基本の考え方。1.4.273 の help では、デフォルトの `check` が未読の最古バッチを返し **処理済みにする**、`--ack` は古い Orca 向け、`--peek` / `--all` は既読にしない、とある。動いている版の公式スキルを優先する。

終わったワーカーの出力を残すためだけにターミナルを開けたままにしない。`worker-release` のあとに `worker-read` する（公式）。

## 6. プロジェクト登録と作業場所

- `orca repo add --path <abs-path>` のデフォルトは `git`。Git ではないディレクトリ、または複数リポジトリの親フォルダは `--kind folder`。
- **観察**: パスがすでに登録済みの場所を指すシンボリックリンクだと、`repo add` は新しい登録ではなく **既存エントリを返す**（リンクが解決されるため）。どうしても別エントリが要るときは、リンクを一時的にどかして実パスを登録し、あとでリンクを戻す、という回避を使った。通常はリンクを登録対象にしない方が安全。
- **観察**: `project setup-update` で旧パスを書き換えられないことがあり、そのときは再インポートを案内された。
- `repo hide` はサイドバーから隠す。ホスト上のセットアップそのものを外すのは `project setup-delete`。
- `setup-delete` の help（1.4.273）: 開いているターミナルや保存済み workspace があると拒否する。`--force` はそのまま外す。**観察**: `--force` は開いていた司令塔ターミナルも切り離す。取り消しにくいので、利用者の承認を取ってからにする。

Orca bot の作業場所は、最後に登録したリポジトリだけではなく、**ホスト上の bot フォルダにある soul / memory** で決まる（公式: soul と memory はプレーンな Markdown。観察: ファイル名は `SOUL.md` であることが多い）。登録を移したら、bot の指示とメモリの作業ディレクトリも更新する。

詳細と回避策は [references/gotchas.md](references/gotchas.md)。

## 7. 起動フラグとアカウント分離

- エージェントを乗せる公式の入口は `orca worktree create --agent <id>` または `orca agent launch`（`terminal create --command` ではない、と help にある）。
- **観察（2026-11、この日は未再検証）**: 当時の設定では、`worktree create --agent` / `agent launch` が Claude に権限スキップフラグ、Codex に approvals/sandbox 回避フラグを付けた。利用者の方針でそれらのフラグを使わないなら、Orca 側の起動設定を直すか、次で代替する。
  - レビュー: `codex exec -s read-only`
  - 実装: `CLAUDE_CONFIG_DIR=<profile-dir> claude -p --allowedTools <必要なツールだけ>`
- **観察**: フォルダの `mise` や `CLAUDE_CONFIG_DIR` は、そのフォルダで開いたセッションには効いても、Orca bot には効かないことがある。公式 help もボットはオーナーとして動くと書いている。アカウントを分けたい作業は、目的の設定ディレクトリで立ち上げた **hub セッション**経由にし、Orca bot に直接やらせない。

## 8. 秘密情報（macOS キーチェーンの注意）

**観察（macOS）**: `security add-generic-password -w` の対話プロンプトは、長い値を **128 文字で切ることがある**。長いトークンを入れるときはプロンプトに貼らず、次のようにする。

```sh
read -rs T && security add-generic-password -U -a "$USER" -s "<service-name>" -w "$T"; unset T
```

1Password のサービスアカウントを使う場合の型（値は出さない）:

1. キーチェーンからサービスアカウントトークンを取り、環境変数にだけ載せる。
2. `op item get <item> --vault <vault> --fields label=<label> --reveal` で目的の鍵を実行中だけ取り出す（不要なアカウント指定は足さない）。
3. 検証は長さ・所定の接頭辞・`op whoami`・取り出した鍵の長さと接頭辞だけ。標準出力やファイルに値を残さない。

項目 ID やトークンそのものは、このスキルにも会話にも書かない。

## 9. 既知の制限

- [stablyai/orca#47690](https://github.com/stablyai/orca/issues/47690)（2026-11-23 報告、1.4.271、オープンを確認）: ワーカー終了後に `orca bot work list` が空になる。`orchestration worker-list` は現在の Run だけを見る、と報告されている。回避は `run-list` のあと、Run ごとに `worker-list`。1.4.273 では未再実験。
- CLI の登録場所の説明は、overview が Settings → General → Orca CLI、reference が Settings → Experimental → CLI、と食い違っている。アプリの表示で確認する。

## 10. このスキルに含めないもの

ホスト固有のターミナルハンドル、repo / bot / machine の ID、ユーザー名、vault / item ID、トークンや鍵。それらは各ホストのメモリや台帳に置き、スキルにはプレースホルダだけを書く。
