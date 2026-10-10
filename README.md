# AgentPets

デスクトップに小さなペットを常駐させ、コーディングエージェントの状態を表情と色で表示する macOS アプリ。

Claude Code や Codex の hook、または外部プロセスから状態を送ると、ペットが即座に反応する。ターミナルを見ていなくても、視界の隅で「まだ動いている」「入力を待っている」「失敗した」が分かる。

## 状態

| status    | スプライト | 絵文字表示       | 色       |
| --------- | ---------- | ---------------- | -------- |
| `idle`    | idle       | 🟢 `(・ω・)`      | グリーン |
| `working` | running    | ⚡ `(•̀ᴗ•́)و`      | イエロー |
| `waiting` | waiting    | ❓ `(･_･;)`       | オレンジ |
| `success` | jumping    | 🎉 `(٩(ˊxDˋ*)و)` | ブルー   |
| `error`   | failed     | 💥 ``(´;ω;`)``   | レッド   |

`success` は 1 度跳ねてから `idle` に戻る。`error` は落ち込んだまま留まる（寿命は下の「状態の寿命」）。
ペットが未設定のとき、およびアトラスを読めなかったときは絵文字表示になる。
システム設定で「視差効果を減らす」が有効なときは、アニメーションを止めて各状態の
先頭フレームを表示する。

### 状態の寿命

状態は送信元ごとに寿命がある。

- hook（`agentpets-hook`）からの `working` / `waiting` / `error` は、30 分なにも届かなければ `idle` 扱いに戻る。
  セッション自体は 2 時間届かなければ消える。
- `agentpets-notify.sh` からの `working` は、10 秒なにも届かなければ `idle` に戻る。
  寿命の確認は 5 秒間隔で行うので、実際に戻るのは最後の通知の 10〜15 秒後になる。
  `agentpets-notify.sh` のそれ以外の状態は 10 分で消える。

### 吹き出し

吹き出しは、狭い枠で末尾が切れても状態が読めるよう、状態を先頭に置く。

```text
入力待ち (Bash) · my-project
```

形式は `<状態語>[ (<詳細>)] · <プロジェクト名>`（プロジェクト名が無ければ送信元名）。
状態語は `作業中` / `入力待ち` / `完了` / `失敗`。`idle` のときは吹き出しを出さない。
マウスを乗せると吹き出しが広がり、`claude · my-project: 入力待ち (Bash)` のように送信元を含む全文を表示する（非常に長い文は下が切れることがある）。
`agentpets-notify.sh` から送った状態は、第2引数の文字列だけを出す。

### 複数セッション

Claude Code と Codex、または複数のセッションが同時に動いているときは、全セッションの中から
`waiting` > `error` > `working` > `success` > `idle` の順で最上位の 1 つを表示する。
同順位なら最後のイベントが新しい方。許可待ちのセッションがあれば、他のセッションが作業中でも
`waiting` が前面に残る。

## 動作環境

- macOS 26.0 以降
- ビルドには Xcode 26 以降（プロジェクト形式 `objectVersion = 90`）。Xcode 27.0 で動作確認済み
- Swift 6.0

## ビルドと起動

```sh
git clone https://github.com/ohioshirt/AgentPets.git
cd AgentPets
open AgentPets.xcodeproj
```

Xcode から実行するか、コマンドラインで:

```sh
xcodebuild build -project AgentPets.xcodeproj -scheme AgentPets \
  -configuration Debug -destination 'platform=macOS'
```

バンドル識別子は Xcode が生成したプレースホルダのままなので、自分の環境で署名する場合は
`PRODUCT_BUNDLE_IDENTIFIER` を差し替える。

起動しても Dock にアイコンは出ず、Cmd+Tab のアプリケーションスイッチャーにも並ばない
（`LSUIElement`）。メニューバーアプリと同じ扱いで、操作の入口はメニューバーのアイコンだけになる。
終了もそこの「Quit」から行う。アプリ自身のメニューバーを持たないので、Cmd+Q は効かない。

## ペットを表示する

メニューバーのアイコンから「ペットフォルダを選択…」で、ペットパッケージが入った
フォルダを選ぶ。フォルダの直下にある `pet.json` を持つディレクトリがペットとして並ぶ。

```text
pets/
└── zundamon/
    ├── pet.json
    └── spritesheet.webp
```

`pet.json` に必要なのは `id` / `displayName` / `description` / `spritesheetPath` の 4 つ。
アトラスは 1536×1872、8 列 × 9 行、セル 192×208、未使用セルは透過。行の並びは上から
idle / running-right / running-left / waving / jumping / failed / waiting / running / review。

Codex の hatch-pet スキルで作ったペットは `${CODEX_HOME:-$HOME/.codex}/pets/` に出力される。
**AgentPets はこの場所を自動では見ない。** 見に行くのは、選んだフォルダだけ。

ウィンドウの既定サイズは 96×104 pt。枠は無いが端をドラッグしてリサイズできる。ただし
掴み代は辺 3pt・隅 12〜15pt しか無いので、実際には右下隅を掴むことになる。大きさと位置は
次回起動時に復元される。メニューの「サイズを既定に戻す」で元に戻せる。

## 状態を送る

### agentpets-hook（Claude Code / Codex）

エージェントの hook から呼ぶコマンドラインツール。hook の stdin に来る JSON を読んで正規化し、
AgentPets へ通知する。どんな入力でも exit 0 で、stdout には何も書かない
（診断が要るときは `AGENTPETS_HOOK_DEBUG=1` で stderr に出る）。

```sh
./scripts/install-hook.sh
```

`Packages/AgentPetsCore` を release ビルドして `~/.local/bin/agentpets-hook` に置き、
設定例を表示する。**設定ファイルは書き換えない。** 表示された内容を自分で足す。

Claude Code（`~/.claude/settings.json` の `hooks`）は、次のイベントに追加する。

- `SessionStart` `UserPromptSubmit` `PreToolUse` `PostToolUse` `PostToolUseFailure`
  `PermissionRequest` `Notification` `Stop` `StopFailure` — `async: true`
- `SessionEnd` — `async` にせず `timeout: 2`

```json
{ "type": "command", "command": "~/.local/bin/agentpets-hook --source claude", "async": true }
```

Codex（`~/.codex/hooks.json` の `hooks`）は、次のイベントに追加し、Codex の `/hooks` で trust する。

- `SessionStart` `SessionEnd` `UserPromptSubmit` `PreToolUse` `PostToolUse`
  `PermissionRequest` `Stop` `Interrupt`

```json
{ "type": "command", "command": "~/.local/bin/agentpets-hook --source codex", "async": true }
```

実際に書かれる `command` は絶対パスで表示される。

### agentpets-notify.sh（手動送信）

hook を介さず、シェルから状態を直接送るためのスクリプト。

```sh
./scripts/agentpets-notify.sh working "テスト実行中"
./scripts/agentpets-notify.sh error   "テストが2件失敗"
./scripts/agentpets-notify.sh idle
```

第1引数が status、第2引数が吹き出しに出す文字列（省略可）。

送信は `DistributedNotificationCenter` への post だけで、macOS 標準の `osascript` しか使わない。
追加のインストールは要らない。AgentPets が起動していなければ通知は黙って捨てられ、
送信側はブロックされない。

## Claude Code のフックから使う

`~/.claude/settings.json`（またはプロジェクトの `.claude/settings.json`）に
`agentpets-hook --source claude` を登録すると、エージェントの動きがそのままペットに出る。
登録するイベントと JSON は上の「agentpets-hook」を参照。`scripts/install-hook.sh` が
絶対パス入りの設定例を表示する。

Codex は `~/.codex/hooks.json` に `agentpets-hook --source codex` を登録し、`/hooks` で trust する。

Claude Code に限らず、シェルから 1 行呼べる仕組みなら何からでも `agentpets-notify.sh` で使える。

## 通信仕様

自分でクライアントを書く場合は、次の通知を投げる。

- 通知名: `com.agentpets.status`
- ペイロード: 通知の `object` に JSON 文字列を載せる（`userInfo` は使わない）

形式は 2 つある。

**簡易形式**（`v` が無い）。`agentpets-notify.sh` が使う。セッション `manual` の状態を直接設定する。

```json
{ "status": "working", "message": "ビルド中" }
```

`message` は省略できる。`status` が既知の 5 種類でなければ通知ごと破棄する。

**イベント形式**（`"v": 2`）。`agentpets-hook` が使う。エージェントが正規化したイベントを送り、
状態はアプリ側がセッションごとに集約する。フィールドと正規化の規則は
[設計書](docs/superpowers/specs/2026-10-10-agent-event-hub-design.md) の §1 を参照。

どちらも、受信側は次のように扱う。

- 文字列の制御文字は空白 1 つに畳み、前後を整える
- 120 文字を超えたら切り詰める（119 文字＋`…`）
- 型に合わない入力は破棄する

## セキュリティ

**待ち受けポートを持たない。** HTTP サーバーのようにポートを開かないので、
ブラウザで開いたページなどアプリ外から到達できる経路が生まれない。

**ファイルへの権限は 2 つ。** App Sandbox を有効にしたまま、
`com.apple.security.files.user-selected.read-only` と
`com.apple.security.files.bookmarks.app-scope` を使う。前者は選択パネルで選ばれたものを
読むため、後者はその許可を次回起動以降も保つため。結果として、一度選んだフォルダは
再許可なしで読み続けられる。読み取りのみで、書き込みはしない。

既知の場所を推測して探すことはしない。ユーザーが選んでいないフォルダには触れない。

**ただし送信元の認証はしない。** 同一ログインセッションの任意のプロセスが、
同じ通知を投げられる。これは `DistributedNotificationCenter` の性質で、
このアプリで防いでいるわけではない。

通知が動かせるのは、5 つの状態のどれを出すかと、上記のとおり検証・整形された短い文字列だけ。
どのペットを描くかはユーザーが選んだフォルダで決まり、送信側からは変えられない。
なりすまされても起きるのはペットの表情が変わることだけになるよう設計している。
送信元の真正性まで必要な用途には向かない。

## テスト

```sh
xcodebuild test -project AgentPets.xcodeproj -scheme AgentPets -destination 'platform=macOS'
```

通知センター経由の受信、`pet.json` の解析、アトラスの寸法検証、フレーム番号の算出、
アニメーションの進み方、ペットパッケージの探索、ウィンドウ矩形の補正を含む。

イベントの正規化・集約・wire 形式は `Packages/AgentPetsCore` のテストで見る
（実 hook から採取した fixture を使う）。

```sh
swift test --package-path Packages/AgentPetsCore
```

`agentpets-hook` の CLI は `scripts/test-hook-cli.sh` で検査する（先に CLI をビルドする）。テスト専用の通知名へ送るため、動作中のアプリには触れない。

```sh
swift build --package-path Packages/AgentPetsCore
scripts/test-hook-cli.sh "$(swift build --package-path Packages/AgentPetsCore --show-bin-path)/agentpets-hook"
```

## ライセンス

MIT License. 詳細は [LICENSE](LICENSE) を参照。
