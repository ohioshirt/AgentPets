# hook stdin の採取と spec §5 の実測（2026-10-10）

plan Task 1 の記録。採取用 hook（`scripts/capture-hook.sh`）を `~/.claude/settings.json` と `~/.codex/hooks.json` に一時登録し、
ユーザーが実エージェントを操作して採った。採取後に両ファイルから外し、Codex はバックアップとの diff が空、
Claude は `hooks` がバックアップと一致（hooks 以外の差は採取中に Claude Code が書き換えた `model` の 1 行のみ）を確認した。

- 環境: Claude Code（`model: claude-opus-5-5`）、Codex（`model: gpt-6-luna`）、macOS 27
- 主な採取セッション: Claude `14524484-…`（C1〜C6）、Codex `01a123bc-…`（X1〜X5）
- 採取ファイルは `~/agentpets-capture/`（commit しない）。下の「根拠」はそのファイル名の時刻部分
- hook の変更は実行中の Claude Code セッションにも即時反映された（採取していたセッション自身の `PreToolUse` も採れた）。
  仕分けは `session_id` で行った

## spec §5 の答え

| 事項 | 結果 | 根拠 |
|---|---|---|
| Claude で中断・手動拒否の後に `idle_prompt` が発火するか | **発火しない**。許可ダイアログで Esc（拒否）、生成中の Esc（中断）のどちらの後も、`Stop`・`idle_prompt` とも来ない（110〜340 秒観測）。正常完了（`Stop`）の後は 59〜61 秒で来る。background subagent 実行中は来ず、完了後の `Stop` から 59 秒で来た | 拒否: `1791594235.920` 以降、`1791595232.254` 以降。中断: `1791596335.146` 以降。正常: `1791594772.256`→`1791594832.504`、`1791597081.342`→`1791597141.624`、`1791597036.184`→`1791597096.291` |
| Codex で許可を手動拒否したときに出る hook | **`Interrupt`**（拒否の 3.6 秒後）。`Stop`・`PostToolUse` は来ない | `1791601768.626`→`1791601772.226` |
| Claude `Notification(agent_needs_input)` の `session_id` | **未採取**（agent view を使うシナリオを実施していない） | — |
| 許可ダイアログ中に並列の別ツールの `PostToolUse` が届くか／`PermissionRequest` に `tool_name` があるか | `tool_name` は**ある**（両ツール）。`tool_use_id` は**無い**（両ツール）。並列指示した 2 つの Bash は両方とも許可を要し、**1 つずつ直列に**許可→実行された。許可不要のツールが並走するケースは作れておらず、**未採取** | `1791597874.223`〜`1791597903.116` |
| Codex でサブエージェント内のツール hook が発火するか、`agent_id` が付くか | **発火し、`agent_id` と `agent_type` が付く**（docs は `Subagent*` にしか記載が無い）。本体のツール hook には `agent_id` キー自体が無い | `1791602106.408`、`1791602106.463` |
| Claude で `PermissionRequest` と `Notification(permission_prompt)` の両方が届くか | **両方届く**。ただし `permission_prompt` は端末で約 6 秒無入力のときだけ（docs どおり）。実測 6.0 秒後。6 秒以内に応答すると来ない | `1791594685.597`→`1791594691.621`、`1791597874.290`→`1791597880.321` |
| Claude の `SessionEnd` で async hook が完了まで走るか | **走る**。`/exit` で async 版と sync 版が同時刻に届いた。他セッションの終了（`reason: "other"`）でも両方届いた | `1791597917.094`（`reason: "prompt_input_exit"`）、`1791600911.191`、`1791601004.175` |
| hook stdin の実フィールドが docs どおりか | 下の「フィールド」節 | fixture |

## Notification の matcher 値のキー

`notification_type`（docs・plan の想定どおり）。`scripts/redact-fixture.py` の `KEEP` の変更は不要。

## 起動の揺れ

同じツール呼び出しの `PreToolUse` と `PermissionRequest` の、`capture-hook.sh` 起動時刻の差（ミリ秒）。

| ツール | 差（ms） |
|---|---|
| Claude | 53.9, 55.2, 76.4, 75.3, 47.1, 81.3, 67.1, 51.6 |
| Codex | 0.1, -0.0, -0.9（`PermissionRequest` が先に起動することがある） |

最大 81.3 ms。猶予 1.0 秒はその 3 倍以上あり、spec の値で足りる。

## spec に無い挙動（spec 改訂の検討対象）

1. **Codex の自動承認でも `PermissionRequest` が来る。** 承認モード "Approve for me" では人の判断を挟まずに許可されるが、
   `PermissionRequest` は発火し、3.1 秒後に `PostToolUse` が来た（`1791601033.389`→`1791601036.462`）。
   spec の規則では数秒間 waiting が表示される。stdin の `permission_mode` は自動承認でも手動承認（"Ask for approval"）でも `default` で、区別できなかった
2. **Claude でツール実行中の Esc はバックグラウンド化として届く。** `PostToolUse` の `tool_response` が
   `"backgroundedByUser": true, "backgroundTaskId": "…"` で返り、そのターンは `Stop` 無しで止まった。
   タスク完了時に、本文が `<task-notification>…` の `UserPromptSubmit` が届いて新しいターンが始まる（ユーザー入力なし）
   （`1791595065.781`、`1791595077.890`）。background subagent の完了でも同じ（`1791597032.941`）
3. **Claude は `SubagentStart` の無い `SubagentStop` を頻繁に出す。** `agent_type: ""`、`last_assistant_message` は入力候補や要約のような文。
   `Stop` の約 1.5 秒後のほか、何もしていない数分後にも単独で来る（セッション `14524484` で 13 件）。spec の「`Subagent*` は捨てる」で落ちる
4. **Claude の `Stop` は background subagent の起動直後に来る**（サブエージェントはまだ実行中）。サブエージェントのツール hook は
   `agent_id` 付きで、spec の規則で落ちる。完了は 2. の `<task-notification>` 経由で本体の新しいターンとして現れる
5. **Codex の `/exit` は `SessionEnd` の `reason: "other"`**。Claude の `/exit` は `"prompt_input_exit"`

## ユーザーの判断（2026-10-10）

- Claude の拒否・中断の後に hook が来ない件: spec のまま（TTL 30 分で回収）
- 1.（Codex 自動承認でも `PermissionRequest`）: spec は変えず当面は許容する。実機で気になったら第 1 期の後で直す
- 2.〜5. は spec の既存規則で扱えるので変更しない

## フィールド

本体セッションで観測したキー（採取セッション 2 つの和集合）。

- 共通: `session_id`、`cwd`、`hook_event_name`、`transcript_path`。Claude は加えて `scratchpad_dir`、`prompt_id`（`SessionStart` を除く）。Codex は `model` と、ターン内のイベントに `turn_id`
- `tool_use_id`: `PreToolUse`・`PostToolUse`（両ツール）、`PostToolUseFailure`（Claude）。`PermissionRequest` には無い
- `agent_id` / `agent_type`: サブエージェント内のツール hook と `Subagent*` のみ
- Claude `PostToolUseFailure`: `error`、`is_interrupt`、`duration_ms`
- Claude `Notification`: `message`、`notification_type`（`title` は今回の 2 種には無かった）
- `SessionStart`: `source: "startup"`（両ツール）

## fixture

`Packages/AgentPetsCore/Tests/AgentPetsCoreTests/Fixtures/` に、plan の正準名で claude 11 件・codex 8 件。
claude はすべてセッション `14524484`、`PermissionRequest.json` と `Stop.json` は C1 の同じターン（`1791594207.449` / `1791594214.370`）。
codex はすべてセッション `01a123bc`。
`StopFailure` は採取できなかった（意図的に起こせない）ので fixture は無い。

## agentpets-hook CLI の実測（Task 6）

`scripts/test-hook-cli.sh` の最終実行（ALL OK）の生出力より:

```
time SessionEnd.json 0.012s
time huge 0.025s
jitter 0.0ms  (x5)
```

- `time`: 0.012 s と 0.025 s。sh / perl の wrapper を含む上限値。Debug ビルドで採取した。上限 0.5 s に対して余裕がある。
- `jitter`: 2 本の CLI を同時起動した Debug ビルドの、`main` 入口での ts 差（検査スクリプトの 5 組、最大 0.0 ms）。
  dyld・プロセス spawn・stdin 読み込みを含まないため、実際の hook 起動の jitter を上限評価するものではない。
- 1.0 秒の猶予の判断は、上の「起動の揺れ」節（Task 1、hook 起動の jitter 最大 81.3 ms）に基づく。

## 結合確認（Task 8）

2026-10-10 に、実機で hook からアプリまでを通して確認した。`scripts/install-hook.sh` で `~/.local/bin/agentpets-hook`（release ビルド）を置き、アプリは Debug ビルドを Xcode から起動した。

### Step 2: サンドボックス内のアプリへの配送

採取済み fixture を `~/.local/bin/agentpets-hook` で再送した。

- `PermissionRequest` は吹き出し `入力待ち (Bash) · demo-project` になり、ホバーすると `claude · demo-project: 入力待ち (Bash)` に広がった。
- 同じセッションの `Stop` は `完了 · demo-project` になった。跳ねる動きは再送した `Stop` で確認した（最初の 1 回はユーザーが見逃した）。
- 旧形式の `agentpets-notify.sh working "テスト実行中"` は吹き出し `テスト実行中` になり、10〜15 秒後に `完了 · demo-project` へ戻った。
- 別プロセスからサンドボックス内のアプリへの配送は、v2 と旧形式のどちらも動いた。診断用の一時ビルドで、どちらも recv → decode → HubStore → show のログを確認した。

### 実機確認で見つかり、直した問題

1. 吹き出しの切り詰め。96×104 のウィンドウで `.lineLimit(2)` が `claude · demo-project: 入力待ち (Bash)` を `claude · demo-proj…` に切り、状態が見えなかった。吹き出しを `<状態語>[ (<詳細>)] · <project|source>` の状態先頭形式にし、全文はホバーで出すようにした（コミット d9398ff、仕様 §2.3 の更新は d145f9d、ホバー表示は 2c6f7ce）。`.help` のツールチップは、非アクティブな non-activating パネルでは出なかったため、ホバーで広がる吹き出しで代えた。
2. テストによる本番通知名の汚染。`AgentPetsTests/StatusNotificationListenerTests` が本番の通知名 `com.agentpets.status` へ実際に通知を送っており（`{"status":"waiting","message":"次の通知"}` を含む）、`xcodebuild test` のたびに、動作中のペットへ 10 分間の manual waiting「次の通知」が入り、実セッションを隠していた。リスナーの通知名を差し替え可能にし、テストは一意なテスト用の名前を使うようにした（コミット 19a02d8）。修正後に `xcodebuild test` を全件走らせ、外部の記録プロセスで本番名への通知が 0 件であることを確認した。

未証明の点として、ライブ確認の最初の旧形式テストでは表示が変わらなかった。後では再現しなかった。直前のテスト実行が manual waiting を送っていたことによる、上の 2 と同じ汚染が原因とみているが、証明はしていない。

### Step 3: 設定の切り替え

- `~/.claude/settings.json`: `agentpets-notify.sh` の 2 件（`SessionStart` の working、`Notification` の `idle_prompt` の waiting）を外した。`agentpets-hook --source claude` を `SessionStart` `UserPromptSubmit` `PreToolUse` `PostToolUse` `PostToolUseFailure` `PermissionRequest` `Notification` `Stop` `StopFailure`（async）と、`SessionEnd`（同期、timeout 2）に追加した。
- `~/.codex/hooks.json`: `agentpets-hook --source codex`（async）を `SessionStart` `SessionEnd` `UserPromptSubmit` `PreToolUse` `PostToolUse` `PermissionRequest` `Stop` `Interrupt` に追加した。
- 変更前の写しは `~/agentpets-capture/backup-task8/` に置いた。JSON として読めることを確認し、Pixoo・herdr・各ゲートの行には触れていない。

### Step 4: 実エージェントでの確認

ユーザーがペットを見て確認し、イベント列は外部の記録プロセスで採った。結果はすべて想定どおり。

- C1（Claude の通常ターン）: `turn.started` → `activity`（pre, Bash）→ `input.requested`（Bash、+53 ms）→ `activity`（post, Bash、+7.3 s）→ `turn.completed`。表示は 作業中 → 入力待ち → 作業中 → 完了（跳ねる）。
- C2（Claude で Esc により拒否）: `入力待ち (Bash)` が残る。既知の制限で、30 分の TTL で消える。
- C3（Claude の生成中に中断）: 次のプロンプトで 作業中 に切り替わり、そのまま残る。既知の制限。
- X1（Codex、Ask for approval。`/tmp` への書き込みは承認不要だった）: 作業中 → 完了。
- X3（Codex の中断）: `turn.started` → `turn.interrupted`（+2.2 s）。そのセッションは idle になり、表示は別セッション（この作業を回している Claude セッション）の 完了 に移った。
- Claude と Codex の同時実行: 許可待ち（入力待ち）が、もう一方が作業中でも最上位に残った。

Codex のセッション ID は UUIDv7 で、別セッションでも先頭 8 桁が同じになる。hub は完全な ID をキーにしているので問題は無い。
