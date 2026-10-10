# Agent Event Hub 設計（第 1 期）

- 日付: 2026-10-10
- 状態: 実装済み（Task 8 の実機結合確認を除く）。実装と hook 採取結果（`docs/superpowers/notes/2026-10-10-hook-capture.md`）に合わせて改訂済み
- 対象 repo: AgentPets

## 目的

ターミナルを見ていなくても、ペットを見れば「動いている／入力待ち／終わった／失敗した」が分かる状態にする。
最終的には StackChan（M5Stack K151）を BLE で同じ状態に反応させる（Codex Pets のデスクペット版）。

第 1 期では AgentPets を hub にし、エージェントの hook イベントを正規化して画面上のペットに出すところまでを作る。

## 全体ロードマップ

| 期 | 内容 | 実機 |
|---|---|---|
| 1（本書） | 正規化イベント、`agentpets-hook` アダプタ、reducer、集約、画面ペットへの出力 | 不要 |
| 2 | BLE wire contract、AgentPets の BLE 出力（CoreBluetooth central） | 要 |
| 3 | StackChan ファームウェア（新規 repo、BLE peripheral、顔表示）。首の動作はさらに後 | 要 |

UWB PoC（`uwb-stackchan-poc`）とは別プロジェクトとする。将来の統合デモでは iPhone と Mac の 2 central が
同時接続することになる。PoC の Arduino-ESP32 BLE ライブラリと session gate がそれを許すかは未検証で、
統合を決めたときに確認する。

## 決定事項

| 決定 | 理由 |
|---|---|
| hook イベントと表示状態を 1:1 にしない。間に正規化イベントを置く | 他ツールへの拡張時に、アダプタ（変換関数）を 1 つ足すだけで済ませる |
| 正規化は同梱の Swift CLI `agentpets-hook` で行う | 変換表を型付きでテストできる。アプリ本体は正規化イベントしか知らない。osascript の起動が不要 |
| 複数セッションは最優先の 1 つを表示する | 裏で入力待ちのセッションを埋もれさせない。BLE 送信量も 1 状態に収まる |
| 表示状態は既存の 5 つ（idle / working / waiting / success / error） | 既存のスプライト行・絵文字・色をそのまま使える |
| hub は AgentPets | 常駐、状態受け口、アトラス読み込み、Bluetooth 権限を持てる .app が既にある |
| waiting は「人の判断（許可・質問への回答）が要る」だけを指す。「次の依頼を待っている」は success／idle | Codex Pets の Needs input と Ready の区別に合わせる |
| 非 idle の全状態に、イベントと TTL の両方の抜け道を持たせる（§2.2） | 中断・拒否・端末終了で hook が来ないことがある（Claude の `Stop` は中断時に発火しない） |

### 現行挙動からの変更

| 項目 | 現行 | 本設計 | 理由 |
|---|---|---|---|
| Claude `SessionStart` | working | idle | 起動しただけでは作業していない |
| Claude `Notification(idle_prompt)` | waiting | `agent.idle`（waiting/working を idle へ） | 応答完了から約 60 秒後の「入力していない」通知であり、判断待ちではない |
| working の自動 idle 化 | 10 秒（旧 `PetViewModel` の `workingTimeout`） | 30 分 | 長いビルド・テストの実行中は hook が来ない。10 秒では作業中に idle へ落ちる |
| 状態の寿命 | working 以外は次の通知まで保持 | §2.2 の TTL | 複数セッション集約では、固着した 1 セッションが他をすべて隠すため |
| 跳ねる条件 | success の通知を受けるたび | 表示中セッションの `turn.completed` 受信時（§2.3） | 集約の切り替わりで、何も完了していないのに跳ねるのを防ぐ |

## 1. 正規化イベント

### 1.1 語彙

| kind | 意味 | Claude Code | Codex |
|---|---|---|---|
| `session.started` | セッション開始 | `SessionStart` | `SessionStart` |
| `session.ended` | セッション終了 | `SessionEnd` | `SessionEnd` |
| `turn.started` | 依頼を受けた | `UserPromptSubmit` | `UserPromptSubmit` |
| `activity` | 作業中の心拍 | `PreToolUse` / `PostToolUse` / `PostToolUseFailure` | `PreToolUse` / `PostToolUse` |
| `input.requested` | 人の判断待ち | `PermissionRequest`、`Notification` の `permission_prompt` / `elicitation_dialog` | `PermissionRequest` |
| `turn.completed` | 応答完了 | `Stop` | `Stop` |
| `turn.failed` | ターン失敗 | `StopFailure` | なし |
| `turn.interrupted` | ユーザー中断 | なし | `Interrupt` |
| `agent.idle` | エージェントが入力を待って止まっている | `Notification(idle_prompt)` | なし |

イベント名の出典は各公式 docs（Claude Code: https://code.claude.com/docs/en/hooks 、
Codex: https://learn.chatgpt.com/docs/hooks.md 、2026-10-10 取得）。docs で確認した挙動:

- Claude の `Stop` は「Does not run if the stoppage occurred due to a user interrupt.」
- Claude の `PermissionDenied` は auto モードでのみ発火し、手動拒否では発火しない（よって採用しない）。
- Claude の `idle_prompt` は応答完了から約 60 秒後、未入力かつ background agent が無いときに発火する。
- Claude の hook stdin に時刻・連番フィールドは記載が無い。許可承認の瞬間に発火する hook も無い。

変換規則:

- `agent_id` を持つイベントと `SubagentStart` / `SubagentStop` は捨てる（サブエージェント由来）。
  herdr 統合のコメントにある「本体ターン終了後に届く `SubagentStop` が idle を working に戻す」問題を避ける。
  Codex のサブエージェント内のツール hook にも `agent_id` が付くことは採取で確認した（§5）。
- `PostToolUseFailure` はツール単位の失敗であってターンの失敗ではないので `activity` とする。
- Claude の `Notification(agent_needs_input)` は捨てる。agent view で別の background セッションが入力待ちになったときの通知で、
  stdin の `session_id` がどのセッションを指すか docs に記載が無く、無関係なセッションを waiting にしうるため（§5 のとおり未採取。採取後に再判断）。
- 表に無いイベント、および matcher 値が表に無い `Notification` は捨てる。
- 変換関数は `(source, hook stdin JSON) -> AgentEvent?` の純粋関数とする。

### 1.2 フィールドと wire 形式

```json
{
  "v": 2,
  "source": "claude",
  "session": "abc123",
  "project": "uwb-stackchan-poc",
  "kind": "input.requested",
  "detail": "Bash",
  "ts": 1791590400.123
}
```

- `source`: `claude` / `codex` / `manual`。CLI の `--source` 引数で決める。
- `session`: hook stdin の `session_id`。
- `project`: hook stdin の `cwd` の末尾要素。無ければ空文字。
- `detail`: 吹き出し用の短い補足（ツール名など）。任意。
- `phase`: `activity` のときだけ `pre`（`PreToolUse`）/ `post`（`PostToolUse` / `PostToolUseFailure`）。§2.1 の waiting 照合に使う。
- `ts`: アダプタ起動時刻（Unix 秒、小数）。hook 側に時刻が無いため、これが入手できる最も早い時刻。
  async hook は別プロセスで並行起動するので、`ts` の順はイベント発生順を保証しない（§2.1 の猶予規則で補う）。
- 送信路は既存の `DistributedNotificationCenter`（名前 `com.agentpets.status`、object に JSON 文字列）。
- `v` を持たない旧形式 `{status, message}` は `manual` ソースのイベントとして受ける（§2.4）。

## 2. reducer と集約

### 2.1 セッション単位の遷移

| 受信 | 次の状態 |
|---|---|
| `turn.started` | working |
| `activity` | working（下の猶予規則あり） |
| `input.requested` | waiting |
| `turn.completed` | success |
| `turn.failed` | error |
| `turn.interrupted` | idle |
| `agent.idle` | waiting / working なら idle、success / error はそのまま |
| `session.started` | 新規セッションなら idle。既存セッションなら状態を変えない |
| `session.ended` | セッションを削除 |

- 順序保護: セッションが最後に適用した `ts` より古いイベントは捨てる。例外は 2 つ。
  - 最後に適用した `ts` より `clockJumpTolerance`（10 秒）を超えて古いイベントは、並行起動の揺れではなく時計の変化とみなし、
    猶予判定と waiting の detail 照合を通さずに適用する。適用後の `lastAppliedTS` はそのイベントの `ts` にする
    （`max` を取ると旧時刻が残り、以後のイベントが落ち続け TTL も効かなくなるため）。
  - 最後に適用した `ts` より古く、その差が `grace` 以内の `input.requested` は、working 中に届いたときに限り適用する（waiting に入る）。
    このとき `lastAppliedTS` は新しい方の値を保つ。理由: Codex は `PreToolUse` と `PermissionRequest` を約 0.1 ms 差で起動し、
    CLI の投函順が逆になることがある。`PreToolUse` が先に working にした後で届く `PermissionRequest` を捨てると、許可待ちを見落とす。
- 猶予規則: waiting / success / error に入った `ts` から 1.0 秒以内の `ts` を持つ `activity` は捨てる。
  `PreToolUse` と `PermissionRequest` がほぼ同時に起動し `PreToolUse` 側が遅れた場合や、
  `Stop` より起動が遅れた `PostToolUse` が、より重要な状態を上書きするのを防ぐ。猶予秒数は設定値で、
  初期値 1.0 秒は §4 の起動の揺れの実測で見直す。
  - 猶予の起点は、その状態に入るイベント（入り直しを含む）を適用するたびに取り直す。
    例外: waiting 中に届いた `detail` が空の `input.requested` は起点を取り直さない。同じ待ちの続きとみなす
    （Claude の `Notification(permission_prompt)` は `PermissionRequest` の約 6 秒後に来る。ここで取り直すと、
    直後に届く一致する `PostToolUse` が猶予に捕まり waiting が固着する）。`detail` が空でない `input.requested` は従来どおり取り直す。
  - 捨てたイベントは「最後に適用した `ts`」を更新しない。
- waiting を抜ける `activity` は、waiting に入ったイベントと `detail`（ツール名）が一致する `PostToolUse` /
  `PostToolUseFailure` 由来のものに限る。許可ダイアログ表示中に並列実行中の別ツールの `PostToolUse` が届いても
  waiting を消さないため。`detail` が空の waiting（`elicitation_dialog` 等）は任意の `activity` で抜ける。
  このため `activity` は `phase`（`pre` / `post`）を持つ。

### 2.2 抜け道の一覧（時間規則は `now` を引数で受ける。すべて設定値）

| 状態 | 抜けるイベント | TTL（最終イベントからの経過） |
|---|---|---|
| working | `input.requested` / `turn.completed` / `turn.failed` / `turn.interrupted` / `agent.idle` / `session.ended` | 30 分で idle |
| waiting | 一致する post `activity`（猶予後、§2.1）/ `turn.*` / `agent.idle` / `session.ended` | 30 分で idle |
| error | `turn.started` / `activity`（猶予後）/ `session.ended` | 30 分で idle |
| success | `turn.started` / `activity`（猶予後）/ `session.ended` | 2 時間で削除（優先度最下位の非 idle なので他を隠さない） |
| idle | 任意のイベント | 2 時間で削除 |

想定する固着ケースと抜け方:

- Claude で許可を Esc で拒否、または生成中に Esc で中断 → `Stop` も `PermissionDenied` も `idle_prompt` も来ない（採取で確認、§5）
  → waiting／working の TTL 30 分で idle。
- Codex で許可を手動拒否 → `Interrupt` が来て `turn.interrupted`（idle）。
- 端末を閉じて `SessionEnd` が届かない → TTL で idle、2 時間で削除。

### 2.3 集約

- 全セッションから優先度 waiting > error > working > success > idle の最上位を 1 つ選ぶ。同順位は最終イベントが新しい方。
- セッション 0 件なら idle。
- 吹き出し文: `<source> · <project>: <状態の短文>[ (<detail>)]`。`MessageText.sanitize`（旧 `StatusPayload.sanitize` から移設）の制御文字除去・120 文字切り詰めを通す。
- 跳ねる動き（`DisplayState.celebrate`）は集約ではなく `HubStore.receive` が決める。受信したイベントが `turn.completed` で、
  集約結果の表示セッションがそのセッションで、かつ受信前後でセッション表が変化したときだけ立てる。
  猶予・順序保護で捨てられたイベントは表を変えないので跳ねない。`Stop` から始まるセッション（直前に状態が無い）も跳ねる。
  集約の切り替わり（例: B の waiting が TTL で消えて A の success が表に出る）では跳ねない。
  同じ見た目（status・文・セッション）は出し直さない（出し直すと跳ねている最中のアニメーションが打ち切られるため）。

### 2.4 manual ソース

旧形式 `{status, message}` は、セッション `manual` の状態を `status` に直接設定する。`message` を `detail` とする。
manual セッションは実セッションを長時間隠さないよう短い寿命を持つ: working は 10 秒（現行挙動を維持。TTL の評価が 5 秒間隔なので、実際に idle へ戻るのは最終イベントの 10〜15 秒後）、
それ以外は 10 分で削除。manual の success は受信のたびに `turn.completed` として扱い、連投でも毎回跳ねる（現行挙動を維持）。

### 2.5 既知の制約

- Claude で長いツールを許可した後、そのツールが終わる（`PostToolUse`）まで waiting のまま表示される。
  許可承認時に発火する hook が無いため。waiting TTL 30 分を超えるツールでは途中で idle になる。
- Codex には `StopFailure` 相当が無く、API エラーで終わったターンは working TTL（30 分）で idle になるまで working のまま。
- 30 分を超える 1 本のツール実行中は idle に落ちる。

### 2.6 既知の制限

実機採取（`docs/superpowers/notes/2026-10-10-hook-capture.md`）で見つかり、第 1 期では直さないと決めたもの。

- Claude で許可を Esc で拒否した場合、および生成中に Esc で中断した場合、`Stop` も `idle_prompt` も来ないので、
  waiting／working のまま TTL 30 分で idle になる（ユーザー承認済み）。
- Codex の自動承認（"Approve for me"）でも `PermissionRequest` が来るため、数秒間 waiting が表示される（ユーザー承認済み。
  `permission_mode` は手動承認と同じ `default` で区別できない）。
- 許可の承認とツールの完了が `PermissionRequest` から 1 秒以内に起きると、その `PostToolUse` は猶予に捕まり、
  次の `Stop` か一致する次の post まで waiting が残る。
- Claude の `Notification(permission_prompt)`（約 6 秒後）が承認と競合すると、長いツールの実行中に偽の waiting が出ることがある。

## 3. 構成

```text
AgentPets/                           repo ルート
├── Packages/AgentPetsCore/          SwiftPM ローカルパッケージ（UI 非依存）。repo 直下に置く
│   ├── Sources/AgentPetsCore/
│   │   ├── AgentEvent.swift         正規化イベントと wire v2 の encode/decode
│   │   ├── Normalizers/             Claude.swift / Codex.swift / Manual.swift
│   │   ├── SessionReducer.swift     (SessionTable, AgentEvent, now) -> SessionTable
│   │   └── Aggregator.swift         SessionTable -> DisplayState
│   ├── Sources/agentpets-hook/      stdin -> 正規化 -> DistributedNotification
│   └── Tests/AgentPetsCoreTests/    fixture と性質テスト（swift-testing）
├── AgentPets/                       アプリターゲット（フォルダ同期グループ）
│   ├── StatusNotificationListener   v2 と旧形式を受け、HubStore へ渡す
│   ├── HubStore（新規）             SessionTable を保持し reducer を適用、5 秒ごとに時間規則を評価
│   ├── DisplaySink（新規 protocol） DisplayState を受け取る口。第 2 期の BLE 出力もここに足す
│   └── PetViewModel                 DisplaySink の実装。workingTimeout は削除し、時間規則は HubStore へ
└── scripts/install-hook.sh          release ビルドして ~/.local/bin へ配置し、hook 設定例を表示
```

- `Packages/` は repo 直下に置く。`AgentPets/` はフォルダ同期グループなので、その配下に置くとパッケージのソースがアプリターゲットに取り込まれる。
- CLI は app bundle に入れない（pbxproj に Copy Files フェーズを手で足すのを避ける）。
  app と CLI は同じ `AgentPetsCore` に依存し、wire 形式の食い違いを防ぐ。
- app ターゲットへのローカルパッケージ追加は Xcode の UI で行う（pbxproj を手で編集しない）。
- テストは既存に合わせて swift-testing（`import Testing`）で書く。

### 3.1 `agentpets-hook` の約束

- 呼び出し: `agentpets-hook --source claude|codex`、stdin に hook の JSON。
- いかなる入力でも exit 0、stdout には何も書かない（Codex は stdout を hook 応答として解釈し、
  `SessionStart` では developer context として注入する）。診断は `AGENTPETS_HOOK_DEBUG=1` のときだけ stderr へ出す。
- 通知を post したら即終了する。
- hook 設定の async 指定:
  - 原則 `async: true`。
  - Claude の `SessionEnd` は同期で短い `timeout` を付ける設定を維持する。async hook も完了まで走ることは採取で確認した（§5）。
  - Codex の `SessionEnd` は Codex 側で常に同期（既定 1 秒、最大 3 秒）。

### 3.2 hook 設定

- コマンドは絶対パスで書く（`/Users/<user>/.local/bin/agentpets-hook`）。hook 実行時の PATH に依存しない。
- `~/.claude/settings.json`: 既存の `agentpets-notify.sh` の行を `agentpets-hook --source claude` に置き換え、
  §1.1 の各イベントに登録する。Pixoo・herdr・各ゲートの行は変更しない。
- `~/.codex/hooks.json`: §1.1 の各イベントに `agentpets-hook --source codex` を追加する。
  追加後に Codex の `/hooks` で trust する必要がある。herdr の行は変更しない。
- 実際の書き換えはユーザー確認後に行う。

## 4. テスト

| 対象 | 確かめること |
|---|---|
| 変換関数 | 両ツールの実 hook stdin を採取した fixture が期待 kind になる。fixture は手書きしない |
| 変換関数 | `agent_id` 付き、`Subagent*`、未知の `Notification` matcher、未知イベントが nil になる |
| reducer | 古い `ts` を捨てる |
| reducer | `input.requested` の 0.5 秒後の `activity` は捨て、2 秒後の `activity` は working にする |
| reducer | 時計が 10 秒を超えて巻き戻ったイベントは、waiting／success／error でも猶予を見ずに適用し、以後のイベントと TTL が効く |
| reducer | working 中に届いた、猶予以内に古い `input.requested` は waiting にし、`lastAppliedTS` を戻さない（Codex の逆順到着を含む実 fixture の通し試験） |
| reducer | waiting 中の `detail` 空の `input.requested` は猶予起点を取り直さず、約 0.6 秒後の一致する post `activity` で waiting を抜ける |
| reducer | `turn.completed` の 0.5 秒後の `activity` で success が working に戻らない |
| reducer | waiting → （中断、以降イベントなし）→ `agent.idle` で idle |
| reducer | waiting → イベントなしで 30 分 → idle。error も同様 |
| reducer | working → 29 分無音では working、30 分で idle |
| reducer | `agent.idle` が success / error を変えない |
| reducer | `session.ended` で削除、2 時間無音で削除 |
| 集約 | waiting と working 混在で waiting／同順位は新しい方／0 件で idle |
| 集約 | セッション A が waiting で固着しても TTL 経過後は B の working が表示される |
| manual | 旧形式 working は 10 秒で消える、waiting は 10 分で消える |
| CLI | 空 stdin・壊れた JSON・未知イベントで exit 0 かつ stdout 空 |
| CLI | 起動から終了までの所要時間を実測する |
| CLI | 2 本を同時に起動したときの `ts` の差（起動の揺れ）を実測し、猶予 1.0 秒の妥当性を記録する |
| reducer | waiting（detail=Bash）中に別ツール（detail=Read）の post `activity` が 2 秒後に来ても waiting のまま |
| reducer | 捨てた `activity` は最終 `ts` を進めない／waiting への入り直しで猶予起点が更新される |
| 集約 | B の waiting が TTL で消えて A の success が表に出ても跳ねない（`HubStore.receive` の判定として検査） |
| 配送 | 別プロセスの CLI が post 直後に exit しても、sandbox 下のアプリ（`ENABLE_APP_SANDBOX = YES`）に届く（手動の結合確認。結果を記録する） |
| 旧経路 | `agentpets-notify.sh working` で画面ペットが working になる |

- fixture 採取: 開発中だけ、stdin をそのままファイルへ保存する採取用 hook を一時登録して両ツールで各イベントを発生させる。
  中断・手動拒否・サブエージェント起動の各ケースも採取する。採取物から個人情報（プロンプト本文、パス）を伏せてから commit する。
- reducer・集約は `now` を注入して sleep なしで検証する。
- コア: `swift test --package-path Packages/AgentPetsCore`。アプリ: `xcodebuild test`。

## 5. 実測結果と未検証事項

採取は 2026-10-10 に実施した。詳細と根拠の `ts` は `docs/superpowers/notes/2026-10-10-hook-capture.md`（以下「採取ノート」）にある。

| 事項 | 結果 |
|---|---|
| Claude で中断・手動拒否の後に `idle_prompt` が発火するか | 発火しない（110〜340 秒観測）。正常完了の後は 59〜61 秒で発火。→ §2.2、§2.6。採取ノート「spec §5 の答え」 |
| Codex で許可を手動拒否したときの hook | `Interrupt`（3.6 秒後）。`Stop`・`PostToolUse` は来ない。採取ノート同上 |
| 許可ダイアログ中の並列ツールの `PostToolUse`、`PermissionRequest` の `tool_name` | `tool_name` は両ツールにある。`tool_use_id` は無い。並列の 2 つの Bash は直列に許可・実行された。同上 |
| Codex のサブエージェント内ツール hook | 発火し、`agent_id` / `agent_type` が付く。本体のツール hook には `agent_id` キーが無い。同上 |
| Claude で `PermissionRequest` と `Notification(permission_prompt)` の両方が届くか | 両方届く。`permission_prompt` は端末で約 6 秒無入力のときだけ。→ §2.1 の空 detail 再入。同上 |
| Claude の `SessionEnd` で async hook が完了まで走るか | 走る。同上 |
| hook stdin の実フィールド | docs どおり。採取ノート「フィールド」 |
| `agentpets-hook` の起動時間 | 最大 0.025 秒（Debug、wrapper 込み）。採取ノート「agentpets-hook CLI の実測」 |
| 起動の揺れ（猶予 1.0 秒の妥当性） | Claude の `PreToolUse` と `PermissionRequest` で最大 81.3 ms、Codex は 0.1 ms 前後で順序が逆になることがある（→ §2.1 の順序保護の例外）。採取ノート「起動の揺れ」 |

採取で見つかった spec 外の挙動（Codex の自動承認でも `PermissionRequest` が来る、Claude のツール実行中の Esc はバックグラウンド化、
単独の `SubagentStop` など）は採取ノート「spec に無い挙動」に記録した。自動承認は §2.6 に載せ、他は既存の規則で扱える。

未検証:

| 事項 | 影響 | 確かめ方 |
|---|---|---|
| Claude `Notification(agent_needs_input)` の `session_id` がどのセッションを指すか（agent view のシナリオ未実施） | 当該セッションのものなら `input.requested` に戻す。それまでは捨てる | 採取用 hook で実測 |
| 許可不要のツールが許可ダイアログ表示中に並走するケース | §2.1 の detail 照合の成否（許可を要する並列ツールは直列だったため作れていない） | 採取用 hook で実測 |
| 別プロセスの CLI からの DistributedNotification が sandbox 下のアプリ（Release ビルドの `~/.local/bin` 配置）に届くか | 現行の `agentpets-notify.sh` 経路と同じ仕組みなので届く見込みだが、自動テストは同一プロセス内のみ | Task 8 の結合確認 |
| Release ビルドの CLI の起動の揺れ | 実測は Debug のみ。1.0 秒の猶予に対して余裕は大きい | Task 8 で必要なら実測 |

## 6. 範囲外

- BLE、StackChan、首の動作（第 2・3 期）
- Pixoo を出力先に統合すること（`DisplaySink` を足せば可能な形にだけしておく）
- 他ツール（Gemini CLI 等）のアダプタ
