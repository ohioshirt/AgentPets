# AgentPets

デスクトップに小さなペットを常駐させ、コーディングエージェントの状態を表情と色で表示する macOS アプリ。

外部プロセスから状態を送ると、ペットが即座に反応する。ターミナルを見ていなくても、視界の隅で「まだ動いている」「入力を待っている」「失敗した」が分かる。

## 状態

| status    | 表示             | 色       |
| --------- | ---------------- | -------- |
| `idle`    | 🟢 `(・ω・)`      | グリーン |
| `working` | ⚡ `(•̀ᴗ•́)و`      | イエロー |
| `waiting` | ❓ `(･_･;)`       | オレンジ |
| `success` | 🎉 `(٩(ˊxDˋ*)و)` | ブルー   |
| `error`   | 💥 ``(´;ω;`)``   | レッド   |

`working` のまま 10 秒間なにも届かなければ、自動的に `idle` へ戻る。

## 動作環境

- macOS 26.5.2 以降
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
App Sandbox 有効のまま動作し、追加の entitlement を必要としない。

**ただし送信元の認証はしない。** 同一ログインセッションの任意のプロセスが、
同じ通知を投げられる。これは `DistributedNotificationCenter` の性質で、
このアプリで防いでいるわけではない。

表示されるのは固定の絵文字と、上記のとおり検証・整形された短い文字列だけなので、
なりすまされても起きるのはペットの表情が変わることだけになるよう設計している。
送信元の真正性まで必要な用途には向かない。

## テスト

```sh
xcodebuild test -project AgentPets.xcodeproj -scheme AgentPets -destination 'platform=macOS'
```

ペイロードの解析、不正入力の拒否、`working` のウォッチドッグ、
通知センター経由の受信までを含む。

## ライセンス

MIT License. 詳細は [LICENSE](LICENSE) を参照。
