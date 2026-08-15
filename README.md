# AgentPets

デスクトップに小さなペットを常駐させ、コーディングエージェントの状態を表情と色で表示する macOS アプリ。

外部プロセスから状態を送ると、ペットが即座に反応する。ターミナルを見ていなくても、視界の隅で「まだ動いている」「入力を待っている」「失敗した」が分かる。

## 状態

| status    | スプライト | 絵文字表示       | 色       |
| --------- | ---------- | ---------------- | -------- |
| `idle`    | idle       | 🟢 `(・ω・)`      | グリーン |
| `working` | running    | ⚡ `(•̀ᴗ•́)و`      | イエロー |
| `waiting` | waiting    | ❓ `(･_･;)`       | オレンジ |
| `success` | jumping    | 🎉 `(٩(ˊxDˋ*)و)` | ブルー   |
| `error`   | failed     | 💥 ``(´;ω;`)``   | レッド   |

`success` は 1 度跳ねてから `idle` に戻る。`error` は落ち込んだまま次の通知を待つ。
ペットが未設定のとき、およびアトラスを読めなかったときは絵文字表示になる。
システム設定で「視差効果を減らす」が有効なときは、アニメーションを止めて各状態の
先頭フレームを表示する。

`working` のまま 10 秒間なにも届かなければ、自動的に `idle` へ戻る。

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

`.claude/settings.json` に設定すると、エージェントの動きがそのままペットに出る。

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/AgentPets/scripts/agentpets-notify.sh working 作業中",
            "async": true
          }
        ]
      }
    ],
    "Notification": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/AgentPets/scripts/agentpets-notify.sh waiting 入力待ち",
            "async": true
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/AgentPets/scripts/agentpets-notify.sh idle",
            "async": true
          }
        ]
      }
    ]
  }
}
```

Claude Code に限らず、シェルから 1 行呼べる仕組みなら何からでも使える。

## 通信仕様

自分でクライアントを書く場合は、次の通知を投げる。

- 通知名: `com.agentpets.status`
- ペイロード: 通知の `object` に JSON 文字列を載せる（`userInfo` は使わない）

```json
{ "status": "working", "message": "ビルド中" }
```

`message` は省略できる。受信側は次のように扱う。

- `status` が既知の 5 種類でなければ通知ごと破棄する
- `message` の制御文字は空白 1 つに畳み、前後を整える
- `message` が 120 文字を超えたら切り詰める

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

ペイロードの解析、不正入力の拒否、`working` のウォッチドッグ、通知センター経由の受信に加え、
`pet.json` の解析、アトラスの寸法検証、フレーム番号の算出、アニメーションの進み方、
ペットパッケージの探索、ウィンドウ矩形の補正までを含む。

## ライセンス

MIT License. 詳細は [LICENSE](LICENSE) を参照。
