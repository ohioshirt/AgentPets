# Agent Event Hub Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Claude Code / Codex の hook イベントを正規化イベントに変換し、セッションごとの状態を集約して AgentPets の画面ペットに出す。

**Architecture:** repo 直下の SwiftPM ローカルパッケージ `AgentPetsCore` に、wire 形式・ツール別変換関数・reducer・集約を純粋関数で置く。同パッケージの実行ファイル `agentpets-hook` が hook の stdin を正規化して `DistributedNotificationCenter` に post する。アプリは受信イベントを `HubStore` で reducer に通し、`DisplaySink`（`PetViewModel`）へ表示状態を渡す。

**Tech Stack:** Swift 6（Apple Swift 6.4 toolchain で確認済み）、SwiftPM、swift-testing、SwiftUI、macOS 26、`DistributedNotificationCenter`。

**Spec:** `docs/superpowers/specs/2026-10-10-agent-event-hub-design.md`（commit 8b4b1b9）。各タスクの実装者は spec も読むこと。

## Global Constraints

- 表示状態は `idle` / `working` / `waiting` / `success` / `error` の 5 つ。raw 値は既存 `PetState` と同じ文字列。
- 集約の優先度は waiting > error > working > success > idle。同順位は最終イベントが新しい方。
- wire 形式は `"v": 2`。通知名は `com.agentpets.status`、object は JSON 文字列。`v` の無い `{status, message}` は manual。
- 猶予 1.0 秒、working / waiting / error の TTL 30 分、セッション削除 2 時間、manual は working 10 秒・その他 10 分で削除。すべて `ReducerConfig` の設定値。
- 吹き出し文は制御文字を空白に畳み、120 文字で切り詰める（119 文字＋`…`）。
- `agentpets-hook` はいかなる入力でも exit 0、stdout には何も書かない。診断は `AGENTPETS_HOOK_DEBUG=1` のときだけ stderr。
- `Packages/` は repo 直下。`AgentPets/` 配下に置かない（フォルダ同期グループに取り込まれる）。
- pbxproj は手で編集しない。ローカルパッケージの追加は Xcode の UI で行う（人間の手作業）。
- テストは swift-testing（`import Testing`）。
- `~/.claude/settings.json` と `~/.codex/hooks.json` の書き換えは、毎回ユーザーの確認を取ってから行う。Pixoo・herdr・各ゲートの行は変更しない。
- fixture は手書きしない。実 hook から採取し、個人情報を伏せてから commit する。
- git の staging はパスを明示する（`git add <path>`）。`git add -A` / `git add .` は使わない。
- macOS に `timeout` コマンドは無い。テストスクリプトで使わない。

## Review Focus

spec がはっきり書いていないが、使っていて最初に踏みそうな入力。各行のテストは担当タスクに入れてある。

1. **時計の巻き戻り**: NTP 補正などで、後から来たイベントの `ts` が大きく過去になる → 順序保護で全部捨てると、そのセッションは TTL まで固まる。10 秒を超えて古いイベントは「時計の変化」とみなして受け入れるのが妥当（Task 4）。
2. **巨大な stdin**: `PostToolUse` の `tool_response` が数 MB → CLI が遅れず exit 0 で終わるべき（Task 6）。
3. **制御文字を含む project 名・detail**: `cwd` の末尾や tool 名に改行・タブ → 吹き出しが崩れず 1 行に畳まれるべき（Task 5）。
4. **AgentPets の起動前から続いているセッション**: 最初に届くのが `activity` や `Stop` → その場でセッションを作る。`Stop` 始まりでも実際の完了なので跳ねてよい（Task 4, Task 7）。
5. **`session_id` が無い・空の stdin**: 壊れた hook 入力 → 捨てて exit 0（Task 3, Task 6）。

---

## File Structure

| パス | 責務 |
|---|---|
| `scripts/capture-hook.sh` | 採取用 hook。stdin をそのままファイルへ保存（Task 1、開発中のみ登録） |
| `scripts/redact-fixture.py` | 採取物から個人情報を伏せる |
| `docs/superpowers/notes/2026-10-10-hook-capture.md` | 採取・実測の記録（spec §5 の答え） |
| `Packages/AgentPetsCore/Package.swift` | パッケージ定義 |
| `Packages/AgentPetsCore/Sources/AgentPetsCore/AgentEvent.swift` | 正規化イベント型 |
| `Packages/AgentPetsCore/Sources/AgentPetsCore/WireCodec.swift` | wire v2 と旧形式の encode/decode、通知名 |
| `Packages/AgentPetsCore/Sources/AgentPetsCore/MessageText.swift` | 吹き出し文の整形（既存 `StatusPayload.sanitize` を移設） |
| `Packages/AgentPetsCore/Sources/AgentPetsCore/Normalizers/HookNormalizer.swift` | source で振り分け、共通フィールド抽出 |
| `Packages/AgentPetsCore/Sources/AgentPetsCore/Normalizers/ClaudeNormalizer.swift` | Claude Code の対応表 |
| `Packages/AgentPetsCore/Sources/AgentPetsCore/Normalizers/CodexNormalizer.swift` | Codex の対応表 |
| `Packages/AgentPetsCore/Sources/AgentPetsCore/SessionReducer.swift` | `PetStatus`、`SessionState`、`SessionTable`、`ReducerConfig`、遷移と TTL |
| `Packages/AgentPetsCore/Sources/AgentPetsCore/Aggregator.swift` | `DisplayState` と集約 |
| `Packages/AgentPetsCore/Sources/agentpets-hook/main.swift` | CLI |
| `Packages/AgentPetsCore/Tests/AgentPetsCoreTests/*.swift` | コアのテスト |
| `Packages/AgentPetsCore/Tests/AgentPetsCoreTests/Fixtures/{claude,codex}/*.json` | 採取した hook stdin |
| `scripts/test-hook-cli.sh` | CLI の exit code・stdout・所要時間・起動の揺れの検査 |
| `scripts/install-hook.sh` | release ビルドして `~/.local/bin` へ配置、hook 設定例を表示 |
| `AgentPets/HubStore.swift` | セッション表の保持、reducer 適用、定期の TTL 評価 |
| `AgentPets/DisplaySink.swift` | 表示の受け口 protocol |
| `AgentPets/PetViewModel.swift` | `DisplaySink` 実装に書き換え |
| `AgentPets/StatusNotificationListener.swift` | wire v2 / 旧形式を受けて `HubStore` へ |
| `AgentPets/AgentPetsApp.swift` | 配線の差し替え |
| `AgentPets/ContentView.swift` | スプライトに `spriteState` を渡す |
| `AgentPets/StatusPayload.swift` | 削除（機能は `WireCodec` / `MessageText` へ移設） |
| `AgentPetsTests/StatusPayloadTests.swift` | 削除（同じケースを `WireCodecTests` へ移植） |
| `AgentPetsTests/PetViewModelTests.swift` | 新 API に合わせて書き換え |
| `AgentPetsTests/HubStoreTests.swift` | 新規 |
| `AgentPetsTests/StatusNotificationListenerTests.swift` | 新 API に合わせて書き換え |
| `README.md` | hook 設定の節を更新 |

---

### Task 1: hook stdin の採取と spec §5 の実測（人間と一緒に行う）

実機のエージェントを対話操作するので、実装者は手順を提示し、ユーザーが操作する。hook 設定の書き換えはユーザーの確認を取ってから行い、終わったら必ず元に戻す。

**Files:**
- Create: `scripts/capture-hook.sh`
- Create: `scripts/redact-fixture.py`
- Create: `docs/superpowers/notes/2026-10-10-hook-capture.md`
- Create: `Packages/AgentPetsCore/Tests/AgentPetsCoreTests/Fixtures/claude/*.json`, `.../Fixtures/codex/*.json`

**Interfaces:**
- Produces: 下記の正準ファイル名の fixture。Task 3 のテストがこの名前で読む。
  - claude: `SessionStart.json` `UserPromptSubmit.json` `PreToolUse.json` `PostToolUse.json` `PostToolUseFailure.json` `PermissionRequest.json` `Notification-permission_prompt.json` `Notification-idle_prompt.json` `Stop.json` `SessionEnd.json` `PreToolUse-subagent.json`
  - codex: `SessionStart.json` `UserPromptSubmit.json` `PreToolUse.json` `PostToolUse.json` `PermissionRequest.json` `Stop.json` `Interrupt.json` `SessionEnd.json`
- Produces: `Notification` の matcher 値が入っている stdin のフィールド名。docs には `notification_type` と記載がある（計画レビューでの確認）。採取で一致を確かめ、異なれば Task 3 の `ClaudeNormalizer.notificationTypeKey` と `redact-fixture.py` の `KEEP` を採取結果に合わせる。

- [ ] **Step 1: 採取スクリプトを書く**

`scripts/capture-hook.sh`:

```sh
#!/bin/sh
# 開発中だけ hook に登録し、stdin をそのまま保存する。
#   capture-hook.sh <source>
# 保存先は $AGENTPETS_CAPTURE_DIR（既定 ~/agentpets-capture）。
# 受け取った時刻（ナノ秒）も別ファイルに残し、起動の揺れの見積もりに使う。
set -u
dir="${AGENTPETS_CAPTURE_DIR:-$HOME/agentpets-capture}"
mkdir -p "$dir" 2>/dev/null || exit 0
stamp="$(perl -MTime::HiRes=time -e 'printf "%.6f", time')"
cat > "$dir/$1-$stamp-$$.json" 2>/dev/null
exit 0
```

```bash
chmod +x scripts/capture-hook.sh
printf '{"x":1}' | AGENTPETS_CAPTURE_DIR=/tmp/ap-cap-check scripts/capture-hook.sh claude; echo "exit=$?"; ls /tmp/ap-cap-check
```

Expected: `exit=0`、`claude-<時刻>-<pid>.json` が 1 件。確認後 `rm -r /tmp/ap-cap-check`。

- [ ] **Step 2: 伏せ字スクリプトを書く**

`scripts/redact-fixture.py`:

```python
#!/usr/bin/env python3
"""採取した hook stdin から個人情報を伏せる。

  python3 -I scripts/redact-fixture.py <in.json> <out.json>

キーの構造と hook_event_name・tool_name・session_id の形は残し、
プロンプト本文・パス・ツールの入出力・メッセージ本文を置き換える。
"""
import json
import sys

KEEP = {"hook_event_name", "tool_name", "notification_type", "matcher",
        "source", "reason", "trigger", "permission_mode", "stop_hook_active",
        "agent_type", "model"}
PATH_KEYS = {"cwd", "transcript_path", "agent_transcript_path", "scratchpad_dir"}


def redact(value, key=None):
    if isinstance(value, dict):
        return {k: redact(v, k) for k, v in value.items()}
    if isinstance(value, list):
        return [redact(v, key) for v in value]
    if key in KEEP or not isinstance(value, str):
        return value
    if key in PATH_KEYS:
        return "/Users/user/projects/demo-project"
    if key in {"session_id", "turn_id", "agent_id", "tool_use_id", "prompt_id"}:
        return value  # 識別子は個人情報ではなく、同一性の検証に要る
    return "<redacted>"


def main():
    src, dst = sys.argv[1], sys.argv[2]
    with open(src, encoding="utf-8") as f:
        data = json.load(f)
    with open(dst, "w", encoding="utf-8") as f:
        json.dump(redact(data), f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")


if __name__ == "__main__":
    main()
```

```bash
printf '{"hook_event_name":"UserPromptSubmit","prompt":"secret","cwd":"~/x","session_id":"s1"}' > /tmp/ap-r.json
python3 -I scripts/redact-fixture.py /tmp/ap-r.json /tmp/ap-r-out.json && cat /tmp/ap-r-out.json; rm /tmp/ap-r.json /tmp/ap-r-out.json
```

Expected: `prompt` が `<redacted>`、`cwd` が `/Users/user/projects/demo-project`、`hook_event_name` と `session_id` はそのまま。

- [ ] **Step 3: 採取用 hook の登録（ユーザー確認を取る）**

ユーザーに次の差分を見せ、承認を得てから追記する。既存の行は消さない。追記前に両ファイルを `~/agentpets-capture/backup/` へコピーしておく。

`~/.claude/settings.json` の `hooks` に、次の各イベントへ `{"type":"command","command":"~/work/tools/AgentPets/scripts/capture-hook.sh claude","async":true}` を 1 件ずつ足す（`Notification` は matcher 無しで全種類）:
`SessionStart` `SessionEnd` `UserPromptSubmit` `PreToolUse` `PostToolUse` `PostToolUseFailure` `PermissionRequest` `Notification` `Stop` `StopFailure` `SubagentStart` `SubagentStop`。
`SessionEnd` だけはもう 1 件、`async` 無しの同じコマンドを `capture-hook.sh claude-sync` として足す（async の SessionEnd が完了するかの比較用）。

`~/.codex/hooks.json` の `hooks` に、次の各イベントへ `{"type":"command","command":"~/work/tools/AgentPets/scripts/capture-hook.sh codex","async":true}` を足す:
`SessionStart` `SessionEnd` `UserPromptSubmit` `PreToolUse` `PostToolUse` `PermissionRequest` `Stop` `Interrupt` `SubagentStart` `SubagentStop`。
Codex では `/hooks` で trust する必要がある（ユーザー操作）。

- [ ] **Step 4: 採取シナリオをユーザーに実行してもらう**

ユーザーに次を順に実行してもらい、各シナリオの開始・終了時刻をメモしてもらう（ファイル名の時刻と突き合わせる）。

| # | ツール | 操作 | spec §5 の問い |
|---|---|---|---|
| C1 | Claude | 新規セッションで「`ls` を実行して」→ 許可 → 完了を待つ | 基本イベント、`PermissionRequest` と `Notification(permission_prompt)` の両方が来るか |
| C2 | Claude | 許可ダイアログで Esc（拒否）→ 70 秒何もしない | 拒否後に何が来るか、`idle_prompt` が来るか |
| C3 | Claude | `sleep 30` を実行させ、実行中に Esc で中断 → 70 秒待つ | 中断時に `Stop` が来ないこと、`idle_prompt` が来るか |
| C4 | Claude | background サブエージェントを起動する依頼（例:「Explore エージェントでこの repo を調べて」）→ 完了まで待つ | サブエージェント内の hook に `agent_id` が付くか。`idle_prompt` の抑止 |
| C5 | Claude | 並列ツール（例:「`sleep 5` と `ls /` を並列で」）で片方だけ許可待ちにする | 許可待ち中に別ツールの `PostToolUse` が来るか、`PermissionRequest` の `tool_name` |
| C6 | Claude | `/exit` で終了 | `SessionEnd` が async と sync の両方で届くか |
| X1 | Codex | 新規セッションで `ls` を実行させる → 許可 → 完了 | 基本イベント |
| X2 | Codex | 許可ダイアログで拒否 | 拒否時に出る hook |
| X3 | Codex | 実行中に中断 | `Interrupt` |
| X4 | Codex | サブエージェントを使う依頼 | サブエージェント内のツール hook と `agent_id` |
| X5 | Codex | 終了 | `SessionEnd` |

PostToolUseFailure は C1〜C5 の途中で失敗するコマンド（例: `ls /nonexistent`）を 1 回混ぜて採る。`StopFailure` は意図的に起こせないので採取できなければ記録に「未採取」と書く。

- [ ] **Step 5: 起動の揺れを計測する**

採取ファイル名の時刻（`capture-hook.sh` 起動時刻）を、C1 と C5 で同じツール呼び出しに属する `PreToolUse` と `PermissionRequest` の間で比べる。

```bash
# ファイル名の時刻部分で並べる（claude-sync- のように source に - を含む名前があるため、区切り位置ではなく正規表現で取る）
ls -1 ~/agentpets-capture | perl -ne 'print "$1 $_" if /-(\d+\.\d+)-\d+\.json$/' | sort -n | head -60
```

差（ミリ秒）を記録に残す。猶予 1.0 秒が揺れの最大値の 3 倍以上あるかを判定する。

- [ ] **Step 6: 採取用 hook を外す（ユーザー確認を取る）**

Step 3 で取ったバックアップと現在のファイルの diff を見せ、追記した行だけを取り除く。取り除いた後、バックアップとの diff が空であることを確認する。

```bash
diff ~/agentpets-capture/backup/settings.json ~/.claude/settings.json && echo CLAUDE_RESTORED
diff ~/agentpets-capture/backup/hooks.json ~/.codex/hooks.json && echo CODEX_RESTORED
```

Expected: `CLAUDE_RESTORED` と `CODEX_RESTORED`。

- [ ] **Step 7: 記録を書く**

`docs/superpowers/notes/2026-10-10-hook-capture.md` に、spec §5 の各行の答えを、根拠になった採取ファイル名とともに書く。加えて次を書く。
- `Notification` の matcher 値が入る stdin のキー名。`notification_type` 以外だった場合は、Step 8 の前に `scripts/redact-fixture.py` の `KEEP` にそのキーを追加する（追加しないと値が `<redacted>` に潰れ、Task 3 の `Notification-*` テストが成り立たない）
- Codex のサブエージェント内ツール hook に `agent_id` が付くか
- 起動の揺れの最大値と、猶予 1.0 秒の判定

spec の規則と食い違う結果が出たら、ここで作業を止めてユーザーに報告する（例: Codex のサブエージェント hook に `agent_id` が付かない、`PermissionRequest` に `tool_name` が無い）。spec を直してから Task 3 以降に進む。

- [ ] **Step 8: fixture を作る**

Interfaces に挙げた正準名ごとに、該当する採取ファイルを 1 つ選んで伏せ字にする。claude の `PermissionRequest.json` と `Stop.json` は C1 の同じセッション（同じ `session_id`）から選ぶ（Task 8 の結合確認で、許可待ち→完了を同一セッションとして確かめるため）。

```bash
mkdir -p Packages/AgentPetsCore/Tests/AgentPetsCoreTests/Fixtures/claude Packages/AgentPetsCore/Tests/AgentPetsCoreTests/Fixtures/codex
python3 -I scripts/redact-fixture.py ~/agentpets-capture/<選んだファイル> Packages/AgentPetsCore/Tests/AgentPetsCoreTests/Fixtures/claude/SessionStart.json
# 以下、正準名ごとに繰り返す
```

`StopFailure` が採れなかった場合、fixture は作らない（Task 3 のテストは `Stop.json` の `hook_event_name` だけを差し替えて作る。テスト内でそう明記する）。

伏せ字後の全 fixture に個人情報が残っていないことを確認する:

```bash
grep -rn -e shigeo -e '/Users/' Packages/AgentPetsCore/Tests/AgentPetsCoreTests/Fixtures | grep -v '/Users/user/projects/demo-project' ; echo "grep-exit=$?"
```

Expected: 何も出力されず `grep-exit=1`。

- [ ] **Step 9: Commit**

```bash
git add scripts/capture-hook.sh scripts/redact-fixture.py docs/superpowers/notes/2026-10-10-hook-capture.md Packages/AgentPetsCore/Tests/AgentPetsCoreTests/Fixtures
git status --porcelain
git commit -m "Capture real hook payloads from Claude Code and Codex"
```

---

### Task 2: パッケージの骨組み、正規化イベント、wire 形式、吹き出し文

**前提:** Task 1 で `Packages/AgentPetsCore/Tests/AgentPetsCoreTests/Fixtures/` が作られていること。`resources: [.copy("Fixtures")]` はディレクトリが無いと `swift test` が失敗する。

**Files:**
- Create: `Packages/AgentPetsCore/Package.swift`
- Create: `Packages/AgentPetsCore/Sources/AgentPetsCore/AgentEvent.swift`
- Create: `Packages/AgentPetsCore/Sources/AgentPetsCore/WireCodec.swift`
- Create: `Packages/AgentPetsCore/Sources/AgentPetsCore/MessageText.swift`
- Create: `Packages/AgentPetsCore/Sources/agentpets-hook/main.swift`（この時点では空の main）
- Test: `Packages/AgentPetsCore/Tests/AgentPetsCoreTests/WireCodecTests.swift`, `MessageTextTests.swift`

**Interfaces:**
- Produces:
  - `public enum Source: String, Codable, Sendable { case claude, codex, manual }`
  - `public enum EventKind: String, Codable, Sendable`（raw 値は spec §1.1 の kind 文字列）
  - `public enum ActivityPhase: String, Codable, Sendable { case pre, post }`
  - `public struct AgentEvent: Codable, Equatable, Sendable { v, source, session, project, kind, detail, phase, ts }`
  - `public enum WireCodec { static let notificationName: String; static func encode(_: AgentEvent) -> String?; static func decode(_ raw: String?, now: Double) -> AgentEvent? }`
  - `public enum MessageText { static let limit = 120; static func sanitize(_: String) -> String }`
  - `public enum PetStatus: String, Sendable, CaseIterable { case idle, working, waiting, success, error }`（`WireCodec` の旧形式で使うのでここで定義）

- [ ] **Step 1: パッケージ定義を書く**

`Packages/AgentPetsCore/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentPetsCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "AgentPetsCore", targets: ["AgentPetsCore"]),
        .executable(name: "agentpets-hook", targets: ["agentpets-hook"]),
    ],
    targets: [
        .target(name: "AgentPetsCore"),
        .executableTarget(name: "agentpets-hook", dependencies: ["AgentPetsCore"]),
        .testTarget(
            name: "AgentPetsCoreTests",
            dependencies: ["AgentPetsCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
```

`Packages/AgentPetsCore/Sources/agentpets-hook/main.swift`（Task 6 で中身を書く）:

```swift
import Foundation
exit(0)
```

- [ ] **Step 2: 失敗するテストを書く**

`Tests/AgentPetsCoreTests/MessageTextTests.swift`（既存 `StatusPayloadTests` の整形ケースを移植）:

```swift
import Testing
@testable import AgentPetsCore

@Suite("MessageText.sanitize")
struct MessageTextTests {
    @Test("制御文字を空白に畳んで前後を整える")
    func collapsesControlCharacters() {
        #expect(MessageText.sanitize("\n失敗\tテスト2件\n") == "失敗 テスト2件")
    }

    @Test("長すぎる文字列を120文字で切り詰める")
    func truncates() {
        let long = String(repeating: "あ", count: 500)
        #expect(MessageText.sanitize(long) == String(repeating: "あ", count: 119) + "…")
    }

    @Test("120文字ちょうどは切り詰めない")
    func keepsExactLimit() {
        let exact = String(repeating: "a", count: 120)
        #expect(MessageText.sanitize(exact) == exact)
    }
}
```

`Tests/AgentPetsCoreTests/WireCodecTests.swift`:

```swift
import Foundation
import Testing
@testable import AgentPetsCore

@Suite("WireCodec")
struct WireCodecTests {
    let sample = AgentEvent(source: .claude, session: "s1", project: "demo",
                            kind: .activity, detail: "Bash", phase: .pre, ts: 100.5)

    @Test("v2 は encode して decode すると元に戻る")
    func roundTrips() throws {
        let raw = try #require(WireCodec.encode(sample))
        #expect(raw.contains(#""v":2"#))
        #expect(WireCodec.decode(raw, now: 999) == sample)
    }

    @Test("v2 の未知の kind は受け付けない")
    func rejectsUnknownKind() {
        let raw = #"{"v":2,"source":"claude","session":"s","project":"","kind":"pwned","detail":"","ts":1}"#
        #expect(WireCodec.decode(raw, now: 1) == nil)
    }

    @Test("v2 の未知の source は受け付けない")
    func rejectsUnknownSource() {
        let raw = #"{"v":2,"source":"evil","session":"s","project":"","kind":"activity","detail":"","ts":1}"#
        #expect(WireCodec.decode(raw, now: 1) == nil)
    }

    @Test("v が 2 以外は受け付けない")
    func rejectsOtherVersion() {
        let raw = #"{"v":3,"source":"claude","session":"s","project":"","kind":"activity","detail":"","ts":1}"#
        #expect(WireCodec.decode(raw, now: 1) == nil)
    }

    @Test("旧形式の各 status を manual イベントに変換する",
          arguments: [
            ("idle", EventKind.turnInterrupted),
            ("working", .turnStarted),
            ("waiting", .inputRequested),
            ("success", .turnCompleted),
            ("error", .turnFailed),
          ])
    func convertsLegacy(status: String, kind: EventKind) throws {
        let event = try #require(WireCodec.decode(#"{"status":"\#(status)","message":"ビルド中"}"#, now: 42))
        #expect(event.source == .manual)
        #expect(event.session == "manual")
        #expect(event.kind == kind)
        #expect(event.detail == "ビルド中")
        #expect(event.ts == 42)
    }

    @Test("旧形式で message が無くても受け付ける")
    func legacyWithoutMessage() {
        #expect(WireCodec.decode(#"{"status":"idle"}"#, now: 1)?.detail == "")
    }

    @Test("旧形式の message も整形する")
    func legacySanitizes() {
        #expect(WireCodec.decode(#"{"status":"error","message":"\n失敗\tテスト2件\n"}"#, now: 1)?.detail == "失敗 テスト2件")
    }

    @Test("旧形式の未知の status は受け付けない")
    func legacyRejectsUnknown() {
        #expect(WireCodec.decode(#"{"status":"pwned","message":"x"}"#, now: 1) == nil)
    }

    @Test("壊れた入力と nil は受け付けない")
    func rejectsMalformed() {
        #expect(WireCodec.decode("not json at all", now: 1) == nil)
        #expect(WireCodec.decode(#"{"status":"#, now: 1) == nil)
        #expect(WireCodec.decode(nil, now: 1) == nil)
    }

    @Test("v2 の detail と project も受信側で整形する")
    func sanitizesV2Fields() throws {
        let raw = #"{"v":2,"source":"claude","session":"s","project":"a\nb","kind":"activity","detail":"x\ty","ts":1}"#
        let event = try #require(WireCodec.decode(raw, now: 1))
        #expect(event.project == "a b")
        #expect(event.detail == "x y")
    }
}
```

- [ ] **Step 3: テストが失敗することを確認**

Run: `swift test --package-path Packages/AgentPetsCore`
Expected: コンパイルエラー（`AgentEvent` / `WireCodec` / `MessageText` が未定義）。

- [ ] **Step 4: 実装を書く**

`Sources/AgentPetsCore/AgentEvent.swift`:

```swift
import Foundation

/// どのエージェントから来たか。`manual` は旧形式（agentpets-notify.sh）。
public enum Source: String, Codable, Sendable {
    case claude, codex, manual
}

/// ツールに依存しない正規化イベントの種類。spec §1.1。
public enum EventKind: String, Codable, Sendable {
    case sessionStarted = "session.started"
    case sessionEnded = "session.ended"
    case turnStarted = "turn.started"
    case activity
    case inputRequested = "input.requested"
    case turnCompleted = "turn.completed"
    case turnFailed = "turn.failed"
    case turnInterrupted = "turn.interrupted"
    case agentIdle = "agent.idle"
}

/// activity がツール実行の前後どちらで発生したか。waiting を抜ける判定に使う。
public enum ActivityPhase: String, Codable, Sendable {
    case pre, post
}

/// 画面に出す 5 状態。raw 値はアプリの `PetState` と同じ。
public enum PetStatus: String, Codable, Sendable, CaseIterable {
    case idle, working, waiting, success, error
}

public struct AgentEvent: Codable, Equatable, Sendable {
    public var v: Int
    public var source: Source
    public var session: String
    public var project: String
    public var kind: EventKind
    public var detail: String
    public var phase: ActivityPhase?
    /// アダプタ起動時刻（Unix 秒）。
    public var ts: Double

    public init(source: Source, session: String, project: String, kind: EventKind,
                detail: String = "", phase: ActivityPhase? = nil, ts: Double) {
        self.v = 2
        self.source = source
        self.session = session
        self.project = project
        self.kind = kind
        self.detail = detail
        self.phase = phase
        self.ts = ts
    }
}
```

`Sources/AgentPetsCore/MessageText.swift`:

```swift
import Foundation

/// 吹き出しに描画する文字列の整形。旧 `StatusPayload.sanitize` から移設。
public enum MessageText {
    /// 吹き出しは幅180pt・2行なので、それを大きく超える文字列は切り詰める。
    public static let limit = 120

    public static func sanitize(_ message: String) -> String {
        let collapsed = String(String.UnicodeScalarView(
            message.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : $0 }
        ))
        let trimmed = collapsed
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")

        guard trimmed.count > limit else { return trimmed }
        return trimmed.prefix(limit - 1) + "…"
    }
}
```

`Sources/AgentPetsCore/WireCodec.swift`:

```swift
import Foundation

/// アダプタとアプリの間の wire 形式。spec §1.2。
public enum WireCodec {
    /// バンドルIDがまだプレースホルダなので、それとは独立した固定名にしている。
    public static let notificationName = "com.agentpets.status"

    public static func encode(_ event: AgentEvent) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(event) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// v2 か旧形式を受け付ける。同一ログインセッションの任意のプロセスが送れるので、
    /// 型に合わないものは捨て、文字列は整形してから返す。
    public static func decode(_ raw: String?, now: Double) -> AgentEvent? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        if let probe = try? JSONDecoder().decode(VersionProbe.self, from: data), let v = probe.v {
            guard v == 2, var event = try? JSONDecoder().decode(AgentEvent.self, from: data) else { return nil }
            event.project = MessageText.sanitize(event.project)
            event.detail = MessageText.sanitize(event.detail)
            return event
        }
        guard let legacy = try? JSONDecoder().decode(Legacy.self, from: data),
              let status = PetStatus(rawValue: legacy.status) else { return nil }
        return AgentEvent(source: .manual, session: "manual", project: "",
                          kind: legacyKind(status),
                          detail: MessageText.sanitize(legacy.message ?? ""), ts: now)
    }

    private static func legacyKind(_ status: PetStatus) -> EventKind {
        switch status {
        case .idle: return .turnInterrupted
        case .working: return .turnStarted
        case .waiting: return .inputRequested
        case .success: return .turnCompleted
        case .error: return .turnFailed
        }
    }

    private struct VersionProbe: Decodable { let v: Int? }
    private struct Legacy: Decodable {
        let status: String
        let message: String?
    }
}
```

- [ ] **Step 5: テストが通ることを確認**

Run: `swift test --package-path Packages/AgentPetsCore`
Expected: 全テスト PASS。生出力の末尾 10 行を作業記録に残す。

- [ ] **Step 6: Commit**

```bash
git add Packages/AgentPetsCore/Package.swift Packages/AgentPetsCore/Sources Packages/AgentPetsCore/Tests/AgentPetsCoreTests/WireCodecTests.swift Packages/AgentPetsCore/Tests/AgentPetsCoreTests/MessageTextTests.swift
git status --porcelain
git commit -m "Add AgentPetsCore package with the v2 wire format"
```

---

### Task 3: ツール別の変換関数

**Files:**
- Create: `Packages/AgentPetsCore/Sources/AgentPetsCore/Normalizers/HookNormalizer.swift`
- Create: `Packages/AgentPetsCore/Sources/AgentPetsCore/Normalizers/ClaudeNormalizer.swift`
- Create: `Packages/AgentPetsCore/Sources/AgentPetsCore/Normalizers/CodexNormalizer.swift`
- Test: `Packages/AgentPetsCore/Tests/AgentPetsCoreTests/NormalizerTests.swift`

**Interfaces:**
- Consumes: Task 1 の fixture（正準名）と `Notification` の matcher キー名、Task 2 の `AgentEvent` / `EventKind` / `ActivityPhase` / `Source`
- Produces: `public enum HookNormalizer { static func normalize(source: Source, stdin: Data, now: Double) -> AgentEvent? }`

- [ ] **Step 1: 失敗するテストを書く**

`Tests/AgentPetsCoreTests/NormalizerTests.swift`:

```swift
import Foundation
import Testing
@testable import AgentPetsCore

private func fixture(_ tool: String, _ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/\(tool)"))
    return try Data(contentsOf: url)
}

/// 実 fixture の hook_event_name だけを差し替える。採取できないイベント用。
private func retargeted(_ data: Data, event: String) throws -> Data {
    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["hook_event_name"] = event
    return try JSONSerialization.data(withJSONObject: object)
}

@Suite("ClaudeNormalizer")
struct ClaudeNormalizerTests {
    @Test("各 fixture が期待する kind になる",
          arguments: [
            ("SessionStart", EventKind.sessionStarted),
            ("SessionEnd", .sessionEnded),
            ("UserPromptSubmit", .turnStarted),
            ("PreToolUse", .activity),
            ("PostToolUse", .activity),
            ("PostToolUseFailure", .activity),
            ("PermissionRequest", .inputRequested),
            ("Notification-permission_prompt", .inputRequested),
            ("Notification-idle_prompt", .agentIdle),
            ("Stop", .turnCompleted),
          ])
    func mapsFixture(name: String, kind: EventKind) throws {
        let event = try #require(HookNormalizer.normalize(source: .claude, stdin: try fixture("claude", name), now: 7))
        #expect(event.kind == kind)
        #expect(event.source == .claude)
        #expect(!event.session.isEmpty)
        #expect(event.project == "demo-project")
        #expect(event.ts == 7)
    }

    @Test("PreToolUse は pre、PostToolUse と PostToolUseFailure は post で tool 名を detail に持つ")
    func activityPhaseAndDetail() throws {
        let pre = try #require(HookNormalizer.normalize(source: .claude, stdin: try fixture("claude", "PreToolUse"), now: 0))
        let post = try #require(HookNormalizer.normalize(source: .claude, stdin: try fixture("claude", "PostToolUse"), now: 0))
        let failure = try #require(HookNormalizer.normalize(source: .claude, stdin: try fixture("claude", "PostToolUseFailure"), now: 0))
        #expect(pre.phase == .pre)
        #expect(post.phase == .post)
        #expect(failure.phase == .post)
        #expect(!pre.detail.isEmpty)
    }

    @Test("PermissionRequest は tool 名を detail に持つ")
    func permissionDetail() throws {
        let event = try #require(HookNormalizer.normalize(source: .claude, stdin: try fixture("claude", "PermissionRequest"), now: 0))
        #expect(!event.detail.isEmpty)
    }

    @Test("StopFailure は turn.failed（Stop の実 fixture のイベント名だけ差し替え）")
    func stopFailure() throws {
        let data = try retargeted(try fixture("claude", "Stop"), event: "StopFailure")
        #expect(HookNormalizer.normalize(source: .claude, stdin: data, now: 0)?.kind == .turnFailed)
    }

    @Test("サブエージェント内のイベントは捨てる")
    func dropsSubagent() throws {
        #expect(HookNormalizer.normalize(source: .claude, stdin: try fixture("claude", "PreToolUse-subagent"), now: 0) == nil)
    }

    @Test("SubagentStart / SubagentStop は捨てる", arguments: ["SubagentStart", "SubagentStop"])
    func dropsSubagentLifecycle(event: String) throws {
        let data = try retargeted(try fixture("claude", "Stop"), event: event)
        #expect(HookNormalizer.normalize(source: .claude, stdin: data, now: 0) == nil)
    }

    @Test("未知のイベントは捨てる")
    func dropsUnknown() throws {
        let data = try retargeted(try fixture("claude", "Stop"), event: "PreCompact")
        #expect(HookNormalizer.normalize(source: .claude, stdin: data, now: 0) == nil)
    }

    @Test("対象外の Notification matcher は捨てる", arguments: ["agent_needs_input", "auth_success", "quota_auto_resume_fired"])
    func dropsOtherNotifications(type: String) throws {
        var object = try #require(try JSONSerialization.jsonObject(with: try fixture("claude", "Notification-idle_prompt")) as? [String: Any])
        object[ClaudeNormalizer.notificationTypeKey] = type
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(HookNormalizer.normalize(source: .claude, stdin: data, now: 0) == nil)
    }

    @Test("session_id が無い・空なら捨てる", arguments: [nil, ""] as [String?])
    func dropsMissingSession(session: String?) throws {
        var object = try #require(try JSONSerialization.jsonObject(with: try fixture("claude", "Stop")) as? [String: Any])
        // String? をそのまま代入すると Optional が値として入るので、nil は明示的に消す
        if let session { object["session_id"] = session } else { object.removeValue(forKey: "session_id") }
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(HookNormalizer.normalize(source: .claude, stdin: data, now: 0) == nil)
    }

    @Test("壊れた入力と空入力は捨てる")
    func dropsMalformed() {
        #expect(HookNormalizer.normalize(source: .claude, stdin: Data(), now: 0) == nil)
        #expect(HookNormalizer.normalize(source: .claude, stdin: Data("{".utf8), now: 0) == nil)
        #expect(HookNormalizer.normalize(source: .claude, stdin: Data("[]".utf8), now: 0) == nil)
    }

    @Test("cwd が無ければ project は空")
    func missingCwd() throws {
        var object = try #require(try JSONSerialization.jsonObject(with: try fixture("claude", "Stop")) as? [String: Any])
        object["cwd"] = nil
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(HookNormalizer.normalize(source: .claude, stdin: data, now: 0)?.project == "")
    }
}

@Suite("CodexNormalizer")
struct CodexNormalizerTests {
    @Test("各 fixture が期待する kind になる",
          arguments: [
            ("SessionStart", EventKind.sessionStarted),
            ("SessionEnd", .sessionEnded),
            ("UserPromptSubmit", .turnStarted),
            ("PreToolUse", .activity),
            ("PostToolUse", .activity),
            ("PermissionRequest", .inputRequested),
            ("Stop", .turnCompleted),
            ("Interrupt", .turnInterrupted),
          ])
    func mapsFixture(name: String, kind: EventKind) throws {
        let event = try #require(HookNormalizer.normalize(source: .codex, stdin: try fixture("codex", name), now: 7))
        #expect(event.kind == kind)
        #expect(event.source == .codex)
        #expect(event.project == "demo-project")
    }

    @Test("SubagentStart / SubagentStop は捨てる", arguments: ["SubagentStart", "SubagentStop"])
    func dropsSubagentLifecycle(event: String) throws {
        let data = try retargeted(try fixture("codex", "Stop"), event: event)
        #expect(HookNormalizer.normalize(source: .codex, stdin: data, now: 0) == nil)
    }

    @Test("agent_id 付きは捨てる")
    func dropsAgentID() throws {
        var object = try #require(try JSONSerialization.jsonObject(with: try fixture("codex", "PreToolUse")) as? [String: Any])
        object["agent_id"] = "sub-1"
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(HookNormalizer.normalize(source: .codex, stdin: data, now: 0) == nil)
    }

    @Test("Claude 専用のイベントは Codex では捨てる", arguments: ["Notification", "StopFailure"])
    func dropsClaudeOnly(event: String) throws {
        let data = try retargeted(try fixture("codex", "Stop"), event: event)
        #expect(HookNormalizer.normalize(source: .codex, stdin: data, now: 0) == nil)
    }
}

@Suite("HookNormalizer")
struct HookNormalizerTests {
    @Test("manual は hook 経路では受け付けない")
    func rejectsManual() throws {
        #expect(HookNormalizer.normalize(source: .manual, stdin: try fixture("claude", "Stop"), now: 0) == nil)
    }
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test --package-path Packages/AgentPetsCore`
Expected: コンパイルエラー（`HookNormalizer` / `ClaudeNormalizer` が未定義）。

- [ ] **Step 3: 実装を書く**

`Sources/AgentPetsCore/Normalizers/HookNormalizer.swift`:

```swift
import Foundation

/// hook の stdin を正規化イベントへ変換する入口。ツールごとの対応表は各 Normalizer に置く。
public enum HookNormalizer {
    public static func normalize(source: Source, stdin: Data, now: Double) -> AgentEvent? {
        guard let input = HookInput(stdin) else { return nil }
        // サブエージェント由来は捨てる。spec §1.1。
        if let agentID = input.string("agent_id"), !agentID.isEmpty { return nil }

        let mapped: (EventKind, String, ActivityPhase?)?
        switch source {
        case .claude: mapped = ClaudeNormalizer.map(input)
        case .codex: mapped = CodexNormalizer.map(input)
        case .manual: return nil
        }
        guard let (kind, detail, phase) = mapped else { return nil }
        return AgentEvent(source: source, session: input.session, project: input.project,
                          kind: kind, detail: detail, phase: phase, ts: now)
    }
}

/// 両ツールに共通するフィールドの取り出し。
struct HookInput {
    let object: [String: Any]
    let event: String
    let session: String

    init?(_ data: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let event = object["hook_event_name"] as? String,
              let session = object["session_id"] as? String, !session.isEmpty else { return nil }
        self.object = object
        self.event = event
        self.session = session
    }

    func string(_ key: String) -> String? { object[key] as? String }

    var project: String {
        guard let cwd = string("cwd"), !cwd.isEmpty else { return "" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    var toolName: String { string("tool_name") ?? "" }
}
```

`Sources/AgentPetsCore/Normalizers/ClaudeNormalizer.swift`:

```swift
import Foundation

/// Claude Code の hook 対応表。spec §1.1。
/// 出典: https://code.claude.com/docs/en/hooks（2026-10-10 取得）と Task 1 の採取記録。
public enum ClaudeNormalizer {
    /// Notification の matcher 値が入る stdin のキー。docs の記載どおりで、Task 1 の採取で確かめた。
    /// 採取結果が異なる場合はこの値を記録どおりに直す。
    public static let notificationTypeKey = "notification_type"

    static func map(_ input: HookInput) -> (EventKind, String, ActivityPhase?)? {
        switch input.event {
        case "SessionStart": return (.sessionStarted, "", nil)
        case "SessionEnd": return (.sessionEnded, "", nil)
        case "UserPromptSubmit": return (.turnStarted, "", nil)
        case "PreToolUse": return (.activity, input.toolName, .pre)
        case "PostToolUse", "PostToolUseFailure": return (.activity, input.toolName, .post)
        case "PermissionRequest": return (.inputRequested, input.toolName, nil)
        case "Stop": return (.turnCompleted, "", nil)
        case "StopFailure": return (.turnFailed, "", nil)
        case "Notification":
            switch input.string(notificationTypeKey) {
            case "permission_prompt", "elicitation_dialog": return (.inputRequested, "", nil)
            case "idle_prompt": return (.agentIdle, "", nil)
            default: return nil
            }
        default: return nil
        }
    }
}
```

`Sources/AgentPetsCore/Normalizers/CodexNormalizer.swift`:

```swift
import Foundation

/// Codex の hook 対応表。spec §1.1。
/// 出典: https://learn.chatgpt.com/docs/hooks.md（2026-10-10 取得）と Task 1 の採取記録。
public enum CodexNormalizer {
    static func map(_ input: HookInput) -> (EventKind, String, ActivityPhase?)? {
        switch input.event {
        case "SessionStart": return (.sessionStarted, "", nil)
        case "SessionEnd": return (.sessionEnded, "", nil)
        case "UserPromptSubmit": return (.turnStarted, "", nil)
        case "PreToolUse": return (.activity, input.toolName, .pre)
        case "PostToolUse": return (.activity, input.toolName, .post)
        case "PermissionRequest": return (.inputRequested, input.toolName, nil)
        case "Stop": return (.turnCompleted, "", nil)
        case "Interrupt": return (.turnInterrupted, "", nil)
        default: return nil
        }
    }
}
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test --package-path Packages/AgentPetsCore`
Expected: 全テスト PASS。失敗した fixture があれば、実装ではなく Task 1 の記録と照合して原因を書く（fixture を書き換えて通さない）。

- [ ] **Step 5: Commit**

```bash
git add Packages/AgentPetsCore/Sources/AgentPetsCore/Normalizers Packages/AgentPetsCore/Tests/AgentPetsCoreTests/NormalizerTests.swift
git status --porcelain
git commit -m "Normalize Claude Code and Codex hook payloads"
```

---

### Task 4: reducer（セッション単位の遷移と TTL）

**Files:**
- Create: `Packages/AgentPetsCore/Sources/AgentPetsCore/SessionReducer.swift`
- Test: `Packages/AgentPetsCore/Tests/AgentPetsCoreTests/SessionReducerTests.swift`

**Interfaces:**
- Consumes: `AgentEvent`, `EventKind`, `ActivityPhase`, `Source`, `PetStatus`
- Produces:
  - `public struct SessionKey: Hashable, Sendable { source: Source; session: String }`
  - `public struct SessionState: Equatable, Sendable { key, project, status: PetStatus, detail, lastAppliedTS, enteredTS, completionCount: Int }`
  - `public struct SessionTable: Equatable, Sendable { public internal(set) var sessions: [SessionKey: SessionState]; public init() }`
  - `public struct ReducerConfig: Sendable { grace, workingTTL, waitingTTL, errorTTL, sessionTTL, manualWorkingTTL, manualTTL, clockJumpTolerance; public init() }`
  - `public enum SessionReducer { static func apply(_: AgentEvent, to: SessionTable, config: ReducerConfig = .init()) -> SessionTable; static func expire(_: SessionTable, now: Double, config: ReducerConfig = .init()) -> SessionTable }`

- [ ] **Step 1: 失敗するテストを書く**

`Tests/AgentPetsCoreTests/SessionReducerTests.swift`:

```swift
import Testing
@testable import AgentPetsCore

private func ev(_ kind: EventKind, _ ts: Double, session: String = "s", source: Source = .claude,
                detail: String = "", phase: ActivityPhase? = nil) -> AgentEvent {
    AgentEvent(source: source, session: session, project: "p", kind: kind, detail: detail, phase: phase, ts: ts)
}

private func run(_ events: [AgentEvent], config: ReducerConfig = .init()) -> SessionTable {
    events.reduce(SessionTable()) { SessionReducer.apply($1, to: $0, config: config) }
}

private func status(_ t: SessionTable, _ session: String = "s", _ source: Source = .claude) -> PetStatus? {
    t.sessions[SessionKey(source: source, session: session)]?.status
}

@Suite("SessionReducer.apply")
struct SessionReducerApplyTests {
    @Test("基本の遷移", arguments: [
        (EventKind.turnStarted, PetStatus.working),
        (.inputRequested, .waiting),
        (.turnCompleted, .success),
        (.turnFailed, .error),
        (.turnInterrupted, .idle),
    ])
    func basic(kind: EventKind, expected: PetStatus) {
        #expect(status(run([ev(.turnStarted, 1), ev(kind, 10)])) == expected)
    }

    @Test("新規セッションの session.started は idle で作る")
    func startedCreatesIdle() {
        #expect(status(run([ev(.sessionStarted, 1)])) == .idle)
    }

    @Test("manual の detail は遷移後も保たれる")
    func manualDetailKept() {
        let t = run([ev(.turnStarted, 1, session: "manual", source: .manual, detail: "テスト実行中")])
        #expect(t.sessions[SessionKey(source: .manual, session: "manual")]?.detail == "テスト実行中")
    }

    @Test("session.ended で削除")
    func ended() {
        #expect(run([ev(.turnStarted, 1), ev(.sessionEnded, 2)]).sessions.isEmpty)
    }

    @Test("既存セッションへの session.started は状態を変えない（resume）")
    func resumeKeepsState() {
        #expect(status(run([ev(.turnStarted, 1), ev(.sessionStarted, 2)])) == .working)
    }

    @Test("最後に適用した ts より古いイベントは捨てる")
    func dropsOlder() {
        #expect(status(run([ev(.turnCompleted, 10), ev(.turnStarted, 9)])) == .success)
    }

    @Test("10 秒を超えて古いイベントは時計の変化とみなして受け入れ、以後はその時刻を基準にする（Review Focus 1）")
    func acceptsClockJump() {
        let t = run([ev(.turnCompleted, 1000), ev(.turnStarted, 900)])
        #expect(status(t) == .working)
        #expect(t.sessions[SessionKey(source: .claude, session: "s")]?.lastAppliedTS == 900)
        // 巻き戻った時計の上で、直後のイベントが落ちず、TTL も効く
        #expect(status(run([ev(.turnCompleted, 1000), ev(.turnStarted, 900), ev(.inputRequested, 995)])) == .waiting)
        #expect(status(SessionReducer.expire(t, now: 900 + 30 * 60)) == .idle)
    }

    @Test("waiting と error は turn.started で working に戻る", arguments: [EventKind.inputRequested, .turnFailed])
    func turnStartedExits(kind: EventKind) {
        #expect(status(run([ev(kind, 10, detail: "Bash"), ev(.turnStarted, 11)])) == .working)
    }

    @Test("同じ ts のイベントは受け入れる")
    func acceptsEqualTS() {
        #expect(status(run([ev(.turnStarted, 10), ev(.inputRequested, 10, detail: "Bash")])) == .waiting)
    }

    @Test("input.requested の 0.5 秒後の activity は捨て、2 秒後の一致する post activity で working")
    func graceAfterWaiting() {
        let base = [ev(.turnStarted, 1), ev(.inputRequested, 10, detail: "Bash")]
        #expect(status(run(base + [ev(.activity, 10.5, detail: "Bash", phase: .pre)])) == .waiting)
        #expect(status(run(base + [ev(.activity, 12, detail: "Bash", phase: .post)])) == .working)
    }

    @Test("turn.completed の 0.5 秒後の activity で success が working に戻らない")
    func graceAfterSuccess() {
        #expect(status(run([ev(.turnCompleted, 10), ev(.activity, 10.5, detail: "Bash", phase: .post)])) == .success)
    }

    @Test("turn.failed の猶予後の activity で working")
    func errorExitsByActivity() {
        #expect(status(run([ev(.turnFailed, 10), ev(.activity, 12, detail: "Bash", phase: .pre)])) == .working)
    }

    @Test("waiting(Bash) 中に別ツール Read の post activity が 2 秒後に来ても waiting")
    func waitingIgnoresOtherTool() {
        let t = run([ev(.inputRequested, 10, detail: "Bash"), ev(.activity, 12, detail: "Read", phase: .post)])
        #expect(status(t) == .waiting)
    }

    @Test("waiting(Bash) 中に同じツールの pre activity は waiting のまま")
    func waitingIgnoresPre() {
        let t = run([ev(.inputRequested, 10, detail: "Bash"), ev(.activity, 12, detail: "Bash", phase: .pre)])
        #expect(status(t) == .waiting)
    }

    @Test("detail が空の waiting は任意の activity（猶予後）で抜ける")
    func emptyDetailWaitingExits() {
        let t = run([ev(.inputRequested, 10), ev(.activity, 12, detail: "Read", phase: .pre)])
        #expect(status(t) == .working)
    }

    @Test("waiting 中に detail 空の input.requested が来ても detail を保ち、猶予の起点を取り直す")
    func reentryKeepsDetailAndResetsGrace() {
        let t = run([ev(.inputRequested, 10, detail: "Bash"), ev(.inputRequested, 16)])
        let s = t.sessions[SessionKey(source: .claude, session: "s")]
        #expect(s?.detail == "Bash")
        #expect(s?.enteredTS == 16)
        // 起点 16 から 0.5 秒後の一致 post は猶予内なので捨てる
        #expect(status(run([ev(.inputRequested, 10, detail: "Bash"), ev(.inputRequested, 16),
                            ev(.activity, 16.5, detail: "Bash", phase: .post)])) == .waiting)
    }

    @Test("捨てた activity は最終 ts を進めない")
    func droppedDoesNotAdvanceTS() {
        let t = run([ev(.inputRequested, 10, detail: "Bash"), ev(.activity, 10.5, detail: "Bash", phase: .post)])
        #expect(t.sessions[SessionKey(source: .claude, session: "s")]?.lastAppliedTS == 10)
    }

    @Test("agent.idle は waiting / working を idle にし、success / error は変えない", arguments: [
        (EventKind.inputRequested, PetStatus.idle),
        (.turnStarted, .idle),
        (.turnCompleted, .success),
        (.turnFailed, .error),
    ])
    func agentIdle(before: EventKind, expected: PetStatus) {
        #expect(status(run([ev(before, 10), ev(.agentIdle, 70)])) == expected)
    }

    @Test("中断（以降イベントなし）→ agent.idle で waiting が解ける")
    func interruptedThenIdlePrompt() {
        #expect(status(run([ev(.turnStarted, 1), ev(.inputRequested, 5, detail: "Bash"), ev(.agentIdle, 65)])) == .idle)
    }

    @Test("turn.completed で completionCount が増える")
    func completionCount() {
        let t = run([ev(.turnStarted, 1), ev(.turnCompleted, 2), ev(.turnStarted, 3), ev(.turnCompleted, 4)])
        #expect(t.sessions[SessionKey(source: .claude, session: "s")]?.completionCount == 2)
    }

    @Test("起動前から続くセッションの最初のイベントが activity なら working で作る（Review Focus 4）")
    func unknownSessionActivity() {
        #expect(status(run([ev(.activity, 5, detail: "Bash", phase: .post)])) == .working)
    }

    @Test("source が違えば同じ session_id でも別セッション")
    func separatesBySource() {
        let t = run([ev(.turnStarted, 1, source: .claude), ev(.inputRequested, 2, source: .codex)])
        #expect(status(t, "s", .claude) == .working)
        #expect(status(t, "s", .codex) == .waiting)
    }
}

@Suite("SessionReducer.expire")
struct SessionReducerExpireTests {
    let minute = 60.0

    @Test("working は 29 分無音では working、30 分で idle")
    func workingTTL() {
        let t = run([ev(.turnStarted, 0)])
        #expect(status(SessionReducer.expire(t, now: 29 * minute)) == .working)
        #expect(status(SessionReducer.expire(t, now: 30 * minute)) == .idle)
    }

    @Test("waiting と error は 30 分で idle", arguments: [EventKind.inputRequested, .turnFailed])
    func waitingErrorTTL(kind: EventKind) {
        let t = run([ev(kind, 0)])
        #expect(status(SessionReducer.expire(t, now: 30 * minute)) == .idle)
    }

    @Test("success は 30 分では残り、2 時間で削除")
    func successTTL() {
        let t = run([ev(.turnCompleted, 0)])
        #expect(status(SessionReducer.expire(t, now: 30 * minute)) == .success)
        #expect(SessionReducer.expire(t, now: 120 * minute).sessions.isEmpty)
    }

    @Test("どの状態も 2 時間無音で削除")
    func sessionTTL() {
        let t = run([ev(.sessionStarted, 0)])
        #expect(SessionReducer.expire(t, now: 120 * minute).sessions.isEmpty)
    }

    @Test("manual の working は 10 秒で idle、それ以外は 10 分で削除")
    func manualTTL() {
        let working = run([ev(.turnStarted, 0, session: "manual", source: .manual)])
        #expect(status(SessionReducer.expire(working, now: 9.9), "manual", .manual) == .working)
        #expect(status(SessionReducer.expire(working, now: 10), "manual", .manual) == .idle)
        let waiting = run([ev(.inputRequested, 0, session: "manual", source: .manual)])
        #expect(status(SessionReducer.expire(waiting, now: 9 * minute), "manual", .manual) == .waiting)
        #expect(SessionReducer.expire(waiting, now: 10 * minute).sessions.isEmpty)
    }
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test --package-path Packages/AgentPetsCore`
Expected: コンパイルエラー（`SessionReducer` などが未定義）。

- [ ] **Step 3: 実装を書く**

`Sources/AgentPetsCore/SessionReducer.swift`:

```swift
import Foundation

public struct SessionKey: Hashable, Sendable {
    public var source: Source
    public var session: String

    public init(source: Source, session: String) {
        self.source = source
        self.session = session
    }
}

public struct SessionState: Equatable, Sendable {
    public var key: SessionKey
    public var project: String
    public var status: PetStatus
    /// working ならツール名、waiting なら許可待ちのツール名、error なら補足。
    public var detail: String
    /// 最後に適用したイベントの ts。順序保護と TTL の基準。
    public var lastAppliedTS: Double
    /// 今の状態に入った ts。猶予の起点。
    public var enteredTS: Double
    /// turn.completed を受けた回数。同じ ts・同じ文の完了が連投されても表が変化したと分かるようにする
    /// （HubStore が「表が変わったときだけ跳ねる」と判定するため。manual の連投で毎回跳ねる）。
    public var completionCount: Int
}

public struct SessionTable: Equatable, Sendable {
    public internal(set) var sessions: [SessionKey: SessionState] = [:]
    public init() {}
}

/// spec §2 の設定値。
public struct ReducerConfig: Sendable {
    public var grace: Double = 1.0
    public var workingTTL: Double = 30 * 60
    public var waitingTTL: Double = 30 * 60
    public var errorTTL: Double = 30 * 60
    public var sessionTTL: Double = 2 * 60 * 60
    public var manualWorkingTTL: Double = 10
    public var manualTTL: Double = 10 * 60
    /// これより大きく過去の ts は並行起動の揺れではなく時計の変化とみなし、受け入れる。
    public var clockJumpTolerance: Double = 10

    public init() {}
}

public enum SessionReducer {
    public static func apply(_ event: AgentEvent, to table: SessionTable,
                             config: ReducerConfig = .init()) -> SessionTable {
        let key = SessionKey(source: event.source, session: event.session)
        var table = table

        if event.kind == .sessionEnded {
            table.sessions[key] = nil
            return table
        }

        let existing = table.sessions[key]
        var state = existing ?? SessionState(key: key, project: event.project, status: .idle, detail: "",
                                             lastAppliedTS: event.ts, enteredTS: event.ts, completionCount: 0)

        if let existing {
            let lag = existing.lastAppliedTS - event.ts
            if lag > 0 && lag <= config.clockJumpTolerance { return table }
        }
        if !event.project.isEmpty { state.project = event.project }

        func enter(_ status: PetStatus, detail: String) {
            state.status = status
            state.detail = detail
            state.enteredTS = event.ts
        }

        switch event.kind {
        case .sessionEnded:
            return table
        case .sessionStarted:
            break
        // hook 由来の turn.* は detail が空。manual は旧形式の message を detail に持つので、そのまま渡す。
        case .turnStarted:
            enter(.working, detail: event.detail)
        case .activity:
            guard shouldAccept(activity: event, in: state, config: config) else { return table }
            enter(.working, detail: event.detail)
        case .inputRequested:
            if state.status == .waiting && event.detail.isEmpty {
                state.enteredTS = event.ts
            } else {
                enter(.waiting, detail: event.detail)
            }
        case .turnCompleted:
            enter(.success, detail: event.detail)
            state.completionCount += 1
        case .turnFailed:
            enter(.error, detail: event.detail)
        case .turnInterrupted:
            enter(.idle, detail: event.detail)
        case .agentIdle:
            if state.status == .waiting || state.status == .working { enter(.idle, detail: "") }
        }

        // ここに来るのは ts が新しいか、時計の変化として受け入れた古いイベント。
        // 後者で max を取ると旧時刻が残り、以後のイベントが落ち続け TTL も効かなくなる。
        state.lastAppliedTS = event.ts
        table.sessions[key] = state
        return table
    }

    private static func shouldAccept(activity event: AgentEvent, in state: SessionState,
                                     config: ReducerConfig) -> Bool {
        switch state.status {
        case .idle, .working:
            return true
        case .success, .error:
            return event.ts - state.enteredTS > config.grace
        case .waiting:
            guard event.ts - state.enteredTS > config.grace else { return false }
            if state.detail.isEmpty { return true }
            return event.phase == .post && event.detail == state.detail
        }
    }

    public static func expire(_ table: SessionTable, now: Double,
                              config: ReducerConfig = .init()) -> SessionTable {
        var table = table
        for (key, state) in table.sessions {
            let age = now - state.lastAppliedTS
            let isManual = key.source == .manual
            if age >= (isManual ? config.manualTTL : config.sessionTTL) {
                table.sessions[key] = nil
                continue
            }
            let ttl: Double?
            switch state.status {
            case .working: ttl = isManual ? config.manualWorkingTTL : config.workingTTL
            case .waiting: ttl = config.waitingTTL
            case .error: ttl = config.errorTTL
            case .idle, .success: ttl = nil
            }
            if let ttl, age >= ttl {
                var idle = state
                idle.status = .idle
                idle.detail = ""
                idle.enteredTS = now
                table.sessions[key] = idle
            }
        }
        return table
    }
}
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test --package-path Packages/AgentPetsCore`
Expected: 全テスト PASS。

- [ ] **Step 5: Commit**

```bash
git add Packages/AgentPetsCore/Sources/AgentPetsCore/SessionReducer.swift Packages/AgentPetsCore/Tests/AgentPetsCoreTests/SessionReducerTests.swift
git status --porcelain
git commit -m "Reduce agent events into per-session states with exits and TTLs"
```

---

### Task 5: 集約

**Files:**
- Create: `Packages/AgentPetsCore/Sources/AgentPetsCore/Aggregator.swift`
- Test: `Packages/AgentPetsCore/Tests/AgentPetsCoreTests/AggregatorTests.swift`

**Interfaces:**
- Consumes: `SessionTable`, `SessionState`, `SessionKey`, `PetStatus`, `MessageText`
- Produces:
  - `public struct DisplayState: Equatable, Sendable { status: PetStatus; message: String; sessionKey: SessionKey?; celebrate: Bool; static let empty; func sameView(as: DisplayState) -> Bool }`（`celebrate` は Aggregator では常に false。Task 7 の `HubStore.receive` が立てる）
  - `public enum Aggregator { static func display(_: SessionTable) -> DisplayState }`
  - `extension PetStatus { public var priority: Int }`

- [ ] **Step 1: 失敗するテストを書く**

`Tests/AgentPetsCoreTests/AggregatorTests.swift`:

```swift
import Testing
@testable import AgentPetsCore

private func table(_ events: [AgentEvent]) -> SessionTable {
    events.reduce(SessionTable()) { SessionReducer.apply($1, to: $0) }
}

private func ev(_ kind: EventKind, _ ts: Double, session: String, source: Source = .claude,
                project: String = "proj", detail: String = "") -> AgentEvent {
    AgentEvent(source: source, session: session, project: project, kind: kind, detail: detail, ts: ts)
}

@Suite("Aggregator")
struct AggregatorTests {
    @Test("セッション 0 件なら idle で文は空")
    func empty() {
        #expect(Aggregator.display(SessionTable()) == .empty)
        #expect(DisplayState.empty.status == .idle)
        #expect(DisplayState.empty.message == "")
    }

    @Test("waiting と working が混在したら waiting")
    func waitingWins() {
        let d = Aggregator.display(table([ev(.turnStarted, 5, session: "a"), ev(.inputRequested, 1, session: "b", detail: "Bash")]))
        #expect(d.status == .waiting)
        #expect(d.sessionKey == SessionKey(source: .claude, session: "b"))
    }

    @Test("優先度は waiting > error > working > success > idle")
    func priorityOrder() {
        #expect(PetStatus.waiting.priority > PetStatus.error.priority)
        #expect(PetStatus.error.priority > PetStatus.working.priority)
        #expect(PetStatus.working.priority > PetStatus.success.priority)
        #expect(PetStatus.success.priority > PetStatus.idle.priority)
    }

    @Test("同順位は最終イベントが新しい方")
    func newerWinsTie() {
        let d = Aggregator.display(table([ev(.turnStarted, 1, session: "a"), ev(.turnStarted, 2, session: "b")]))
        #expect(d.sessionKey?.session == "b")
    }

    @Test("A の waiting が TTL で消えると B の working が表示される")
    func stuckWaitingExpires() {
        let t = table([ev(.inputRequested, 0, session: "a", detail: "Bash"), ev(.turnStarted, 1700, session: "b")])
        #expect(Aggregator.display(t).sessionKey?.session == "a")
        let expired = SessionReducer.expire(t, now: 1800)
        #expect(Aggregator.display(expired).sessionKey?.session == "b")
        #expect(Aggregator.display(expired).status == .working)
    }

    @Test("吹き出し文は source・project・状態・detail を含む")
    func message() {
        let d = Aggregator.display(table([ev(.inputRequested, 1, session: "a", project: "uwb", detail: "Bash")]))
        #expect(d.message == "claude · uwb: 入力待ち (Bash)")
    }

    @Test("project が空なら source だけ")
    func messageWithoutProject() {
        let d = Aggregator.display(table([ev(.turnStarted, 1, session: "a", source: .codex, project: "")]))
        #expect(d.message == "codex: 作業中")
    }

    @Test("idle なら文は空")
    func idleMessage() {
        #expect(Aggregator.display(table([ev(.sessionStarted, 1, session: "a")])).message == "")
    }

    @Test("manual は detail をそのまま文にする")
    func manualMessage() {
        let d = Aggregator.display(table([ev(.turnStarted, 1, session: "manual", source: .manual, project: "", detail: "テスト実行中")]))
        #expect(d.message == "テスト実行中")
    }

    @Test("制御文字を含む project と detail でも 1 行に畳む（Review Focus 3）")
    func controlCharacters() {
        let d = Aggregator.display(table([ev(.inputRequested, 1, session: "a", project: "a\nb", detail: "x\ty")]))
        #expect(!d.message.contains("\n"))
        #expect(!d.message.contains("\t"))
    }

    @Test("集約結果は celebrate を立てない")
    func neverCelebrates() {
        let d = Aggregator.display(table([ev(.turnStarted, 1, session: "a"), ev(.turnCompleted, 2, session: "a")]))
        #expect(d.status == .success)
        #expect(d.celebrate == false)
    }

    @Test("sameView は celebrate 以外が同じなら true")
    func sameView() {
        let k = SessionKey(source: .claude, session: "a")
        let x = DisplayState(status: .success, message: "m", sessionKey: k, celebrate: true)
        let y = DisplayState(status: .success, message: "m", sessionKey: k, celebrate: false)
        #expect(x.sameView(as: y))
        #expect(!x.sameView(as: DisplayState(status: .success, message: "n", sessionKey: k, celebrate: false)))
    }
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test --package-path Packages/AgentPetsCore`
Expected: コンパイルエラー（`Aggregator` / `DisplayState` が未定義）。

- [ ] **Step 3: 実装を書く**

`Sources/AgentPetsCore/Aggregator.swift`:

```swift
import Foundation

/// 画面と（第 2 期の）BLE に出す 1 つの状態。
public struct DisplayState: Equatable, Sendable {
    public var status: PetStatus
    public var message: String
    public var sessionKey: SessionKey?
    /// 表示中セッションが今まさに turn.completed を受けた。跳ねる合図。
    /// 集約は立てない。HubStore.receive が、適用したイベントと表示中セッションが一致したときだけ立てる。
    public var celebrate: Bool

    public static let empty = DisplayState(status: .idle, message: "", sessionKey: nil, celebrate: false)

    public init(status: PetStatus, message: String, sessionKey: SessionKey?, celebrate: Bool = false) {
        self.status = status
        self.message = message
        self.sessionKey = sessionKey
        self.celebrate = celebrate
    }

    /// celebrate を除いて同じ見た目か。HubStore の重複排除に使う。
    public func sameView(as other: DisplayState) -> Bool {
        status == other.status && message == other.message && sessionKey == other.sessionKey
    }
}

extension PetStatus {
    /// spec §2.3。大きいほど優先。
    public var priority: Int {
        switch self {
        case .waiting: return 4
        case .error: return 3
        case .working: return 2
        case .success: return 1
        case .idle: return 0
        }
    }

    var phrase: String {
        switch self {
        case .idle: return ""
        case .working: return "作業中"
        case .waiting: return "入力待ち"
        case .success: return "完了"
        case .error: return "失敗"
        }
    }
}

public enum Aggregator {
    public static func display(_ table: SessionTable) -> DisplayState {
        let top = table.sessions.values.max { a, b in
            (a.status.priority, a.lastAppliedTS) < (b.status.priority, b.lastAppliedTS)
        }
        guard let top else { return .empty }
        return DisplayState(status: top.status, message: message(for: top), sessionKey: top.key)
    }

    private static func message(for state: SessionState) -> String {
        if state.key.source == .manual { return MessageText.sanitize(state.detail) }
        guard state.status != .idle else { return "" }
        let head = state.project.isEmpty
            ? state.key.source.rawValue
            : "\(state.key.source.rawValue) · \(state.project)"
        let tail = state.detail.isEmpty ? "" : " (\(state.detail))"
        return MessageText.sanitize("\(head): \(state.status.phrase)\(tail)")
    }
}
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test --package-path Packages/AgentPetsCore`
Expected: 全テスト PASS。

- [ ] **Step 5: Commit**

```bash
git add Packages/AgentPetsCore/Sources/AgentPetsCore/Aggregator.swift Packages/AgentPetsCore/Tests/AgentPetsCoreTests/AggregatorTests.swift
git status --porcelain
git commit -m "Aggregate sessions into one display state by priority"
```

---

### Task 6: `agentpets-hook` CLI とインストールスクリプト

**Files:**
- Modify: `Packages/AgentPetsCore/Sources/agentpets-hook/main.swift`
- Create: `scripts/test-hook-cli.sh`
- Create: `scripts/install-hook.sh`

**Interfaces:**
- Consumes: `HookNormalizer.normalize`, `WireCodec.encode`, `WireCodec.notificationName`, `Source`
- Produces: 実行ファイル `agentpets-hook --source claude|codex`。`~/.local/bin/agentpets-hook` に配置される。

- [ ] **Step 1: 失敗する検査スクリプトを書く**

`scripts/test-hook-cli.sh`:

```sh
#!/bin/sh
# agentpets-hook の約束を検査する。spec §3.1、§4。
#   scripts/test-hook-cli.sh <agentpets-hook のパス>
set -u
bin="$1"
fixtures="$(cd "$(dirname "$0")/.." && pwd)/Packages/AgentPetsCore/Tests/AgentPetsCoreTests/Fixtures"
fail=0

check() { # name, stdin-file, args...
    name="$1"; input="$2"; shift 2
    out="$("$bin" "$@" < "$input")"
    code=$?
    if [ "$code" -ne 0 ] || [ -n "$out" ]; then
        echo "FAIL $name exit=$code stdout=[$out]"; fail=1
    else
        echo "ok   $name"
    fi
}

tmp="$(mktemp -d)"
: > "$tmp/empty"
printf '{' > "$tmp/broken"
printf '{"hook_event_name":"PreCompact","session_id":"s"}' > "$tmp/unknown"
printf '{"hook_event_name":"Stop"}' > "$tmp/nosession"
# 5MB の tool_response（Review Focus 2）
perl -e 'print q({"hook_event_name":"PostToolUse","session_id":"s","tool_name":"Bash","tool_response":"), "x" x 5000000, q("})' > "$tmp/huge"

check empty      "$tmp/empty"     --source claude
check broken     "$tmp/broken"    --source claude
check unknown    "$tmp/unknown"   --source claude
check nosession  "$tmp/nosession" --source claude
check huge       "$tmp/huge"      --source claude
check no-source  "$fixtures/claude/Stop.json"
check bad-source "$fixtures/claude/Stop.json" --source evil
check manual-src "$fixtures/claude/Stop.json" --source manual
check claude     "$fixtures/claude/Stop.json" --source claude
check codex      "$fixtures/codex/SessionEnd.json" --source codex

# 所要時間（spec §5: Codex SessionEnd の既定 1 秒に収まるか）
for f in "$fixtures/codex/SessionEnd.json" "$tmp/huge"; do
    perl -MTime::HiRes=time -e '$t=time; system(@ARGV); printf "time %s %.3fs\n", $ARGV[-1], time-$t' \
        sh -c "\"$bin\" --source codex < \"$f\"" "$(basename "$f")"
done

# 起動の揺れ（2 本同時起動時の ts 差）
for i in 1 2 3 4 5; do
    AGENTPETS_HOOK_DEBUG=1 "$bin" --source claude < "$fixtures/claude/PreToolUse.json" 2> "$tmp/a$i" &
    AGENTPETS_HOOK_DEBUG=1 "$bin" --source claude < "$fixtures/claude/PermissionRequest.json" 2> "$tmp/b$i" &
    wait
    perl -e 'for (@ARGV) { open F, $_; local $/; $s=<F>; push @t, $1 if $s =~ /"ts":([0-9.]+)/ } printf "jitter %.1fms\n", abs($t[0]-$t[1])*1000 if @t==2' "$tmp/a$i" "$tmp/b$i" | tee -a "$tmp/jitter"
done
# grep -c は 0 件でも "0" を出して exit 1 する。|| echo 0 を付けると "0\n0" になり比較が壊れる。
jitters="$(grep -c '^jitter' "$tmp/jitter" 2>/dev/null)"
jitters="${jitters:-0}"
if [ "$jitters" -ne 5 ]; then echo "FAIL jitter lines=$jitters (expected 5)"; fail=1; fi

rm -r "$tmp"
[ "$fail" -eq 0 ] && echo "ALL OK" || { echo "FAILED"; exit 1; }
```

```bash
chmod +x scripts/test-hook-cli.sh
swift build --package-path Packages/AgentPetsCore
scripts/test-hook-cli.sh "$(swift build --package-path Packages/AgentPetsCore --show-bin-path)/agentpets-hook"
```

注意: `claude` / `codex` の検査と jitter 計測は実際に通知を post するので、AgentPets が起動していれば画面の表示が変わる。

- [ ] **Step 2: 検査が失敗することを確認**

Expected: この時点の `main.swift` は `exit(0)` だけなので、各 `check` は `ok` だが stderr に ts が出ず `FAIL jitter lines=0 (expected 5)`、最終行 `FAILED`。

- [ ] **Step 3: CLI を実装する**

`Sources/agentpets-hook/main.swift`:

```swift
import AgentPetsCore
import Foundation

// hook から呼ばれる。いかなる入力でも exit 0、stdout には何も書かない。spec §3.1。
// Codex は stdout を hook の応答として解釈するため。

let startedAt = Date().timeIntervalSince1970
let debug = ProcessInfo.processInfo.environment["AGENTPETS_HOOK_DEBUG"] == "1"

func log(_ message: String) {
    guard debug else { return }
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

let arguments = CommandLine.arguments
var source: Source?
if let index = arguments.firstIndex(of: "--source"), index + 1 < arguments.count {
    source = Source(rawValue: arguments[index + 1])
}

let input = FileHandle.standardInput.readDataToEndOfFile()

guard let source, source != .manual else {
    log("ignored: --source must be claude or codex")
    exit(0)
}
guard let event = HookNormalizer.normalize(source: source, stdin: input, now: startedAt),
      let payload = WireCodec.encode(event) else {
    log("ignored: not a mapped hook event")
    exit(0)
}

DistributedNotificationCenter.default().postNotificationName(
    Notification.Name(WireCodec.notificationName),
    object: payload,
    userInfo: nil,
    deliverImmediately: true
)
log(payload)
exit(0)
```

- [ ] **Step 4: 検査が通ることを確認**

```bash
swift build --package-path Packages/AgentPetsCore
scripts/test-hook-cli.sh "$(swift build --package-path Packages/AgentPetsCore --show-bin-path)/agentpets-hook"
```

Expected: 全 `ok`、`time` 2 行、`jitter` 5 行、最終行 `ALL OK`。生出力をそのまま作業記録へ残し、`time` の最大値と `jitter` の最大値を `docs/superpowers/notes/2026-10-10-hook-capture.md` に追記する。`time` が 0.5 秒を超えたら作業を止めて報告する。`jitter` の最大値の 3 倍が猶予 1.0 秒を超えたら報告する。

- [ ] **Step 5: インストールスクリプトを書く**

`scripts/install-hook.sh`:

```sh
#!/bin/sh
# agentpets-hook を release ビルドして ~/.local/bin に置き、hook 設定例を表示する。
# 設定ファイルは書き換えない。spec §3.2。
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
swift build --package-path "$root/Packages/AgentPetsCore" -c release --product agentpets-hook
bin="$(swift build --package-path "$root/Packages/AgentPetsCore" -c release --show-bin-path)/agentpets-hook"
mkdir -p "$HOME/.local/bin"
cp "$bin" "$HOME/.local/bin/agentpets-hook"
dest="$HOME/.local/bin/agentpets-hook"
echo "installed: $dest"
cat <<EOF

Claude Code (~/.claude/settings.json の hooks): 次の各イベントに追加する。
  SessionStart UserPromptSubmit PreToolUse PostToolUse PostToolUseFailure
  PermissionRequest Notification Stop StopFailure
    {"type": "command", "command": "$dest --source claude", "async": true}
  SessionEnd（async にしない）
    {"type": "command", "command": "$dest --source claude", "timeout": 2}

Codex (~/.codex/hooks.json の hooks): 次の各イベントに追加し、/hooks で trust する。
  SessionStart SessionEnd UserPromptSubmit PreToolUse PostToolUse
  PermissionRequest Stop Interrupt
    {"type": "command", "command": "$dest --source codex", "async": true}
  （SessionEnd は Codex 側で常に同期実行される。async の指定は無視されるが害は無い）
EOF
```

```bash
chmod +x scripts/install-hook.sh
sh -n scripts/install-hook.sh && echo SYNTAX_OK
```

Expected: `SYNTAX_OK`。実際のインストールは Task 8 で行う。

- [ ] **Step 6: Commit**

```bash
git add Packages/AgentPetsCore/Sources/agentpets-hook/main.swift scripts/test-hook-cli.sh scripts/install-hook.sh docs/superpowers/notes/2026-10-10-hook-capture.md
git status --porcelain
git commit -m "Add the agentpets-hook adapter CLI"
```

---

### Task 7: アプリへの組み込み（HubStore・DisplaySink・PetViewModel・Listener）

**Files:**
- Create: `AgentPets/DisplaySink.swift`
- Create: `AgentPets/HubStore.swift`
- Modify: `AgentPets/PetViewModel.swift`（全面書き換え）
- Modify: `AgentPets/StatusNotificationListener.swift`
- Modify: `AgentPets/AgentPetsApp.swift:66-83`（`AppDelegate`）
- Modify: `AgentPets/ContentView.swift:23-31`（`PetSpriteView` に `spriteState` を渡す）
- Delete: `AgentPets/StatusPayload.swift`, `AgentPetsTests/StatusPayloadTests.swift`
- Test: `AgentPetsTests/PetViewModelTests.swift`（全面書き換え）, `AgentPetsTests/HubStoreTests.swift`（新規）, `AgentPetsTests/StatusNotificationListenerTests.swift`（書き換え）

**Interfaces:**
- Consumes: `AgentPetsCore` の `AgentEvent`, `WireCodec`, `SessionReducer`, `SessionTable`, `ReducerConfig`, `Aggregator`, `DisplayState`, `PetStatus`
- Produces:
  - `protocol DisplaySink: AnyObject { func show(_ display: DisplayState) }`（アプリモジュールは既定で MainActor）
  - `final class HubStore { init(sink: DisplaySink, config: ReducerConfig = .init(), clock: @escaping () -> Double = { Date().timeIntervalSince1970 }); func receive(_ event: AgentEvent); func tick(); func start(interval: TimeInterval = 5); private(set) var table: SessionTable }`
  - `PetViewModel: DisplaySink { currentState: PetState; spriteState: PetState; message: String; eventID: Int }`
  - `StatusNotificationListener(onEvent: @escaping (AgentEvent) -> Void)`

- [ ] **Step 1: ローカルパッケージをアプリに追加する（人間の手作業）**

ユーザーに依頼する: Xcode で `AgentPets.xcodeproj` を開き、File > Add Package Dependencies… > Add Local… で `Packages/AgentPetsCore` を選び、プロダクト `AgentPetsCore` を `AgentPets` ターゲットと `AgentPetsTests` ターゲットに追加する。`agentpets-hook` はどのターゲットにも追加しない。

完了後に確認する:

```bash
git diff --stat AgentPets.xcodeproj/project.pbxproj
grep -n 'XCLocalSwiftPackageReference\|AgentPetsCore' AgentPets.xcodeproj/project.pbxproj | head
```

Expected: pbxproj に `XCLocalSwiftPackageReference` と `AgentPetsCore` が現れる。

テスト実行時に「Class ... is implemented in both」のような重複定義の警告が出た場合（静的ライブラリが app と test bundle の両方にリンクされた場合）は、`AgentPetsTests` ターゲットへの追加を外し、`@testable import AgentPets` 経由で型が見えるかを確認する。どちらにしたかを記録する。

- [ ] **Step 2: 失敗するテストを書く**

`AgentPetsTests/PetViewModelTests.swift`（全面置き換え）:

```swift
//
//  PetViewModelTests.swift
//  AgentPetsTests
//

import AgentPetsCore
import Testing
@testable import AgentPets

@Suite("PetViewModel.show")
@MainActor
struct PetViewModelTests {
    let a = SessionKey(source: .claude, session: "a")
    let b = SessionKey(source: .claude, session: "b")

    func display(_ status: PetStatus, _ key: SessionKey?, celebrate: Bool = false, message: String = "") -> DisplayState {
        DisplayState(status: status, message: message, sessionKey: key, celebrate: celebrate)
    }

    @Test("表示状態と文をそのまま反映する")
    func reflects() {
        let vm = PetViewModel()
        vm.show(display(.working, a, message: "claude · p: 作業中"))
        #expect(vm.currentState == .working)
        #expect(vm.spriteState == .working)
        #expect(vm.message == "claude · p: 作業中")
    }

    @Test("celebrate 付きの success で跳ねる（spriteState が success、eventID が増える）")
    func celebrates() {
        let vm = PetViewModel()
        vm.show(display(.working, a))
        let before = vm.eventID
        vm.show(display(.success, a, celebrate: true))
        #expect(vm.spriteState == .success)
        #expect(vm.eventID == before + 1)
    }

    @Test("success のまま celebrate が続けて来ても毎回跳ねる（manual の連投）")
    func celebratesRepeatedly() {
        let vm = PetViewModel()
        vm.show(display(.success, a, celebrate: true))
        let before = vm.eventID
        vm.show(display(.success, a, celebrate: true))
        #expect(vm.spriteState == .success)
        #expect(vm.eventID == before + 1)
    }

    @Test("celebrate 無しの success は跳ねず、idle のクリップを流す（集約の切り替わり）")
    func noCelebrationOnSwitch() {
        let vm = PetViewModel()
        vm.show(display(.waiting, b))
        vm.show(display(.success, a))
        #expect(vm.currentState == .success)
        #expect(vm.spriteState == .idle)
    }

    @Test("同じ表示が続いても eventID は増えない")
    func stableOnSameDisplay() {
        let vm = PetViewModel()
        vm.show(display(.working, a))
        let before = vm.eventID
        vm.show(display(.working, a))
        #expect(vm.eventID == before)
    }

    @Test("spriteState が変わるたびに eventID が増える")
    func bumpsOnSpriteChange() {
        let vm = PetViewModel()
        let start = vm.eventID
        vm.show(display(.working, a))
        vm.show(display(.waiting, a))
        #expect(vm.eventID == start + 2)
    }
}
```

`AgentPetsTests/HubStoreTests.swift`:

```swift
//
//  HubStoreTests.swift
//  AgentPetsTests
//

import AgentPetsCore
import Testing
@testable import AgentPets

@MainActor
final class RecordingSink: DisplaySink {
    var shown: [DisplayState] = []
    func show(_ display: DisplayState) { shown.append(display) }
}

@Suite("HubStore")
@MainActor
struct HubStoreTests {
    @Test("受信したイベントを reducer に通して sink に出す")
    func receives() {
        let sink = RecordingSink()
        let hub = HubStore(sink: sink, clock: { 100 })
        hub.receive(AgentEvent(source: .claude, session: "s", project: "p", kind: .inputRequested, detail: "Bash", ts: 99))
        #expect(sink.shown.last?.status == .waiting)
    }

    @Test("表示中セッションの turn.completed だけが celebrate を立てる")
    func celebratesOnlyDisplayedCompletion() {
        let sink = RecordingSink()
        let hub = HubStore(sink: sink, clock: { 100 })
        hub.receive(AgentEvent(source: .claude, session: "a", project: "p", kind: .turnStarted, ts: 90))
        hub.receive(AgentEvent(source: .claude, session: "a", project: "p", kind: .turnCompleted, ts: 91))
        #expect(sink.shown.last?.celebrate == true)

        // b が waiting で表に出ている間の a の完了は跳ねない
        hub.receive(AgentEvent(source: .claude, session: "b", project: "p", kind: .inputRequested, detail: "Bash", ts: 92))
        hub.receive(AgentEvent(source: .claude, session: "a", project: "p", kind: .turnCompleted, ts: 93))
        #expect(sink.shown.last?.status == .waiting)
        #expect(sink.shown.last?.celebrate == false)
    }

    @Test("Stop 直後の猶予内 activity や tick で同じ見た目を出し直さない（跳ねる動きを打ち切らない）")
    func dedupesSameView() {
        let sink = RecordingSink()
        let hub = HubStore(sink: sink, clock: { 100 })
        hub.receive(AgentEvent(source: .claude, session: "a", project: "p", kind: .turnCompleted, ts: 90))
        let count = sink.shown.count
        hub.receive(AgentEvent(source: .claude, session: "a", project: "p", kind: .activity, detail: "Bash", phase: .post, ts: 90.5))
        // clock は 100 固定なので、この tick で期限切れになるセッションは無い前提
        hub.tick()
        #expect(sink.shown.count == count)
    }

    @Test("捨てられた turn.completed は、同時に他セッションが期限切れになっても跳ねない")
    func droppedCompletionWithExpiryDoesNotCelebrate() {
        let sink = RecordingSink()
        var now = 0.0
        let hub = HubStore(sink: sink, clock: { now })
        hub.receive(AgentEvent(source: .claude, session: "old", project: "p", kind: .inputRequested, detail: "Bash", ts: 0))
        hub.receive(AgentEvent(source: .claude, session: "a", project: "p", kind: .turnCompleted, ts: 1795))
        now = 1800  // old の waiting が TTL 30 分で idle になる時刻
        // a への古い ts（順序保護で捨てられる）の turn.completed
        hub.receive(AgentEvent(source: .claude, session: "a", project: "p", kind: .turnCompleted, ts: 1794))
        #expect(sink.shown.last?.sessionKey?.session == "a")
        #expect(sink.shown.last?.celebrate == false)
    }

    @Test("manual の success は初回も連投も毎回 celebrate")
    func manualSuccessCelebrates() throws {
        let sink = RecordingSink()
        let hub = HubStore(sink: sink, clock: { 0 })
        hub.receive(try #require(WireCodec.decode(#"{"status":"success","message":"完了"}"#, now: 0)))
        #expect(sink.shown.last?.celebrate == true)
        hub.receive(try #require(WireCodec.decode(#"{"status":"success","message":"完了"}"#, now: 0)))
        #expect(sink.shown.last?.celebrate == true)
        #expect(sink.shown.count == 2)
    }

    @Test("tick で TTL が評価される")
    func tickExpires() {
        let sink = RecordingSink()
        var now = 0.0
        let hub = HubStore(sink: sink, clock: { now })
        hub.receive(AgentEvent(source: .claude, session: "s", project: "p", kind: .turnStarted, ts: 0))
        now = 30 * 60
        hub.tick()
        #expect(sink.shown.last?.status == .idle)
    }

    @Test("旧形式の working は 10 秒後の tick で idle（現行挙動の維持）")
    func legacyWorkingTimeout() throws {
        let sink = RecordingSink()
        var now = 0.0
        let hub = HubStore(sink: sink, clock: { now })
        hub.receive(try #require(WireCodec.decode(#"{"status":"working","message":"ビルド中"}"#, now: 0)))
        #expect(sink.shown.last?.status == .working)
        now = 10
        hub.tick()
        #expect(sink.shown.last?.status == .idle)
    }
}
```

`AgentPetsTests/StatusNotificationListenerTests.swift`（`appliesDeliveredNotification` と `ignoresUnknownState` を置き換え、`post` と `waitUntil` は既存のまま残す）:

```swift
    @Test("v2 の通知を AgentEvent として渡す")
    func deliversV2() async throws {
        var received: [AgentEvent] = []
        let listener = StatusNotificationListener { received.append($0) }
        listener.start()

        let event = AgentEvent(source: .claude, session: "s", project: "p", kind: .turnCompleted, ts: 1)
        post(try #require(WireCodec.encode(event)))

        try await waitUntil { received.contains(event) }
    }

    @Test("旧形式の通知も manual イベントとして渡す")
    func deliversLegacy() async throws {
        var received: [AgentEvent] = []
        let listener = StatusNotificationListener { received.append($0) }
        listener.start()

        post(#"{"status":"success","message":"完了"}"#)

        try await waitUntil { received.contains { $0.source == .manual && $0.kind == .turnCompleted && $0.detail == "完了" } }
    }

    @Test("不正な通知は捨てる")
    func ignoresInvalid() async throws {
        var received: [AgentEvent] = []
        let listener = StatusNotificationListener { received.append($0) }
        listener.start()

        post(#"{"status":"pwned","message":"x"}"#)
        post(#"{"status":"waiting","message":"次の通知"}"#)

        // 後から送った正常な通知が届いた時点で、不正な方は捨てられたと判断できる。
        // 実 hook が同じ通知名で送ってくることがあるので、件数ではなく中身で判定する。
        try await waitUntil { received.contains { $0.detail == "次の通知" } }
        #expect(!received.contains { $0.detail == "x" })
    }
```

ファイル先頭の import に `import AgentPetsCore` を足す。

- [ ] **Step 3: テストが失敗することを確認**

Run: `xcodebuild test -project AgentPets.xcodeproj -scheme AgentPets -destination 'platform=macOS' 2>&1 | tail -20`
Expected: コンパイルエラー（`DisplaySink` / `HubStore` / `show` が未定義）。

- [ ] **Step 4: 実装を書く**

`AgentPets/DisplaySink.swift`:

```swift
//
//  DisplaySink.swift
//  AgentPets
//

import AgentPetsCore

/// 集約した表示状態の出力先。画面のペットのほか、第 2 期で BLE をここに足す。
protocol DisplaySink: AnyObject {
    func show(_ display: DisplayState)
}
```

`AgentPets/HubStore.swift`:

```swift
//
//  HubStore.swift
//  AgentPets
//

import AgentPetsCore
import Foundation

/// 全セッションの状態を持ち、届いたイベントと時間経過を表示状態に変える。
final class HubStore {
    private(set) var table = SessionTable()
    private let sink: DisplaySink
    private let config: ReducerConfig
    private let clock: () -> Double
    private var timer: Timer?
    private var lastShown: DisplayState?

    init(sink: DisplaySink, config: ReducerConfig = .init(),
         clock: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.sink = sink
        self.config = config
        self.clock = clock
    }

    func receive(_ event: AgentEvent) {
        let applied = SessionReducer.apply(event, to: table, config: config)
        // expire の前に比べる。後で比べると、捨てられたイベントでも他セッションの期限切れで「変化あり」になる。
        let changed = applied != table
        table = SessionReducer.expire(applied, now: clock(), config: config)
        var display = Aggregator.display(table)
        // 跳ねるのは、表示中のセッションが今まさに完了したときだけ。spec §2.3。
        // 猶予や順序保護で捨てられたイベントは表を変えないので、跳ねない。
        let key = SessionKey(source: event.source, session: event.session)
        display.celebrate = event.kind == .turnCompleted && display.sessionKey == key && changed
        publish(display)
    }

    func tick() {
        table = SessionReducer.expire(table, now: clock(), config: config)
        publish(Aggregator.display(table))
    }

    /// 同じ見た目を出し直さない。出し直すと PetViewModel が success を idle に読み替え、
    /// 跳ねている最中のアニメーションを打ち切るため。
    private func publish(_ display: DisplayState) {
        if !display.celebrate, let lastShown, lastShown.sameView(as: display) { return }
        lastShown = display
        sink.show(display)
    }

    /// manual の working を 10 秒で戻すため、TTL の評価は短い間隔で回す。
    /// .common モードに入れないと、メニューを開いている間だけ時間が進まない。
    func start(interval: TimeInterval = 5) {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    // アプリと同じ寿命（AppDelegate が所有）なので timer の解除は持たない。
}
```

`AgentPets/PetViewModel.swift`（全面置き換え）:

```swift
//
//  PetViewModel.swift
//  AgentPets
//
//  Created by shigeo on 2026/08/15.
//

import AgentPetsCore
import Foundation
import Observation

@MainActor
@Observable
final class PetViewModel: DisplaySink {
    /// 絵文字表示と色に使う、集約結果そのものの状態。
    var currentState: PetState = .idle
    /// スプライトで再生する状態。集約の切り替わりで success が表に出たときは、
    /// 跳ねずに跳ねた後の姿（idle）を流すため currentState と分ける。
    var spriteState: PetState = .idle
    var message: String = ""

    /// スプライトをやり直す連番。同じ状態のまま跳ね直すときにも増やす。
    private(set) var eventID = 0

    /// 跳ねるかどうかは HubStore が `celebrate` で決める。ここは見た目への写像だけを持つ。
    func show(_ display: DisplayState) {
        let sprite: PetState = display.status == .success && !display.celebrate ? .idle : PetState(display.status)

        if display.celebrate || sprite != spriteState { eventID &+= 1 }
        currentState = PetState(display.status)
        spriteState = sprite
        message = display.message
    }
}

extension PetState {
    init(_ status: PetStatus) {
        switch status {
        case .idle: self = .idle
        case .working: self = .working
        case .waiting: self = .waiting
        case .success: self = .success
        case .error: self = .error
        }
    }
}
```

`AgentPets/StatusNotificationListener.swift`（全面置き換え）:

```swift
//
//  StatusNotificationListener.swift
//  AgentPets
//

import AgentPetsCore
import Foundation

/// 外部プロセス（agentpets-hook、agentpets-notify.sh）から届く通知を受け取り、イベントとして渡す。
///
/// HTTP の待ち受けポートを持たないため、ブラウザで開いたページなど
/// アプリ外から到達できる経路が生まれない。ただし同一ログインセッションの
/// 任意のプロセスが同じ通知を投げられる点は変わらないので、
/// 受け取った内容は `WireCodec.decode` で検証してから使う。
@MainActor
final class StatusNotificationListener: NSObject {

    static let notificationName = Notification.Name(WireCodec.notificationName)

    private let onEvent: (AgentEvent) -> Void

    init(onEvent: @escaping (AgentEvent) -> Void) {
        self.onEvent = onEvent
        super.init()
    }

    func start() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleStatusNotification(_:)),
            name: Self.notificationName,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // 配送スレッドを前提にできないので、ペイロードを取り出してから MainActor へ渡す
    @objc private nonisolated func handleStatusNotification(_ notification: Notification) {
        let raw = notification.object as? String
        let now = Date().timeIntervalSince1970
        Task { @MainActor [weak self] in
            guard let self, let event = WireCodec.decode(raw, now: now) else { return }
            self.onEvent(event)
        }
    }
}
```

`AgentPets/AgentPetsApp.swift` の `AppDelegate` を次に置き換える:

```swift
/// ペットのウィンドウと通知リスナーはアプリと同じ寿命で生きる必要がある。
/// Scene の body 評価中に `@State` へ書き戻すやり方では参照が保持されず、
/// リスナーが即座に解放されて購読が外れるため、delegate 側で所有する。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let viewModel = PetViewModel()
    let library = PetLibrary()
    private(set) var windowController: FloatingWindowController?
    private var listener: StatusNotificationListener?
    private var hub: HubStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        library.restore()

        let controller = FloatingWindowController(
            rootView: ContentView(viewModel: viewModel, library: library)
        )
        controller.showWindow(nil)
        windowController = controller

        let hub = HubStore(sink: viewModel)
        hub.start()
        self.hub = hub

        let listener = StatusNotificationListener { [weak hub] event in hub?.receive(event) }
        listener.start()
        self.listener = listener
    }

    func applicationWillTerminate(_ notification: Notification) {
        library.releaseFolderAccess()
    }
}
```

`AgentPets/ContentView.swift` の `.sprite` 分岐で `viewModel.currentState` を使っている 2 か所（`PetAnimation.clip(for:)` と `PetSpriteView(state:)`）を `viewModel.spriteState` に置き換える。絵文字表示（`emojiPet`）は `currentState` のまま。

削除:

```bash
git rm AgentPets/StatusPayload.swift AgentPetsTests/StatusPayloadTests.swift
```

- [ ] **Step 5: テストが通ることを確認**

```bash
xcodebuild test -project AgentPets.xcodeproj -scheme AgentPets -destination 'platform=macOS' 2>&1 | tail -15
swift test --package-path Packages/AgentPetsCore 2>&1 | tail -5
```

Expected: 両方 PASS（`** TEST SUCCEEDED **` とパッケージ側の全件成功）。生出力の末尾を作業記録へ残す。

- [ ] **Step 6: Commit**

```bash
git add AgentPets.xcodeproj/project.pbxproj AgentPets/DisplaySink.swift AgentPets/HubStore.swift AgentPets/PetViewModel.swift AgentPets/StatusNotificationListener.swift AgentPets/AgentPetsApp.swift AgentPets/ContentView.swift AgentPetsTests/PetViewModelTests.swift AgentPetsTests/HubStoreTests.swift AgentPetsTests/StatusNotificationListenerTests.swift
git status --porcelain
git commit -m "Route events through HubStore into the pet view"
```

（`git rm` 済みの 2 ファイルは staging 済み。`git status --porcelain` で `D ` として出ることを確認する。）

---

### Task 8: インストール、hook 設定の切り替え、結合確認（人間と一緒に行う）

**Files:**
- Modify: `README.md`（「状態を送る」「Claude Code のフックから使う」節）
- Modify: `docs/superpowers/notes/2026-10-10-hook-capture.md`（結合確認の記録を追記）

**Interfaces:**
- Consumes: `scripts/install-hook.sh`、Task 7 のアプリ

- [ ] **Step 1: アプリをビルドして起動、CLI をインストール**

```bash
xcodebuild build -project AgentPets.xcodeproj -scheme AgentPets -configuration Debug -destination 'platform=macOS' 2>&1 | tail -3
scripts/install-hook.sh
```

Expected: `** BUILD SUCCEEDED **`、`installed: ~/.local/bin/agentpets-hook` と設定例。アプリはユーザーに Xcode から起動してもらう。

- [ ] **Step 2: 別プロセスからの配送を確認（sandbox 下）**

アプリを起動し直してセッション表を空にしてから、次の順で行う。各段階でユーザーに画面を確認してもらい、結果を記録に残す。

1. 旧経路（manual）:

```bash
scripts/agentpets-notify.sh working "テスト実行中"
```

ペットが working（吹き出し「テスト実行中」）になり、10〜15 秒（TTL 10 秒＋tick 間隔 5 秒）で idle に戻る。

2. hook 経路（別プロセスから sandbox 下のアプリへ）:

```bash
~/.local/bin/agentpets-hook --source claude < Packages/AgentPetsCore/Tests/AgentPetsCoreTests/Fixtures/claude/PermissionRequest.json
```

ペットが waiting（`claude · demo-project: 入力待ち (...)`）になる。

3. 同じセッションの完了:

```bash
~/.local/bin/agentpets-hook --source claude < Packages/AgentPetsCore/Tests/AgentPetsCoreTests/Fixtures/claude/Stop.json
```

2 つの fixture は Task 1 Step 8 で同じセッションから選んであるので、ペットが 1 回跳ねて idle の姿に戻り、吹き出しは `claude · demo-project: 完了` になる。

- [ ] **Step 3: hook 設定を切り替える（ユーザー確認を取る）**

両設定ファイルを `~/agentpets-capture/backup/` へ再度コピーしてから、次の差分をユーザーに見せて承認を得る。
- `~/.claude/settings.json`: `agentpets-notify.sh` を呼ぶ 2 行（`SessionStart` と `Notification idle_prompt`）を削除し、`install-hook.sh` が表示した Claude 用の行を各イベントに追加。Pixoo・herdr・各ゲートの行は触らない。
- `~/.codex/hooks.json`: Codex 用の行を各イベントに追加。herdr の行は触らない。Codex で `/hooks` を開いて trust してもらう。

書き換え後、JSON として壊れていないことを確認する:

```bash
python3 -I -c "import json,sys; [json.load(open(p)) for p in sys.argv[1:]]; print('JSON_OK')" ~/.claude/settings.json ~/.codex/hooks.json
```

Expected: `JSON_OK`。

- [ ] **Step 4: 実エージェントで結合確認**

ユーザーに Task 1 の C1・C2・C3・X1・X3 を再実行してもらい、各操作でペットの表示が spec §2 の表どおりに変わるかを確認する。Claude と Codex を同時に動かし、片方が許可待ちのとき waiting が優先されることも確認する。結果を記録へ追記する。

- [ ] **Step 5: README を更新**

「状態を送る」の節に `agentpets-hook` と hook 設定（`scripts/install-hook.sh` が表示する内容）を書き、`agentpets-notify.sh` は手動送信用として残す旨を書く。「Claude Code のフックから使う」節の JSON 例を `agentpets-hook --source claude` に差し替える。状態の節の「`working` のまま 10 秒間なにも届かなければ」を、「hook からの working は 30 分、`agentpets-notify.sh` からの working は 10 秒」に直す。

- [ ] **Step 6: Commit**

```bash
git add README.md docs/superpowers/notes/2026-10-10-hook-capture.md
git status --porcelain
git commit -m "Document agentpets-hook setup and record the integration check"
```

---

## Self-Review 結果

- spec の網羅: §1.1 対応表 → Task 3。§1.2 wire → Task 2。§2.1 遷移・順序保護・猶予・detail 照合 → Task 4。§2.2 TTL → Task 4。§2.3 集約・跳ねる条件 → Task 5、Task 7。§2.4 manual → Task 2、Task 4、Task 7。§3 構成 → Task 2〜7。§3.1 CLI の約束 → Task 6。§3.2 hook 設定 → Task 8。§4 テスト → 各タスク。§5 未検証事項 → Task 1、Task 6 Step 4。
- spec からの補足（Deviations として記録する）: Review Focus 1 の「10 秒を超えて古い ts は受け入れる」（`clockJumpTolerance`）は spec に無い規則。跳ねる判定は `HubStore.receive` が `DisplayState.celebrate` を立てる方式（表示中セッションへの turn.completed で表が変わったときだけ）。集約の切り替わりでは `spriteState` を idle にして跳ねない。同じ見た目は出し直さない（跳ねる動きの打ち切り防止）。いずれも spec §2.3 の実現方法。`Stop` 始まりのセッションも跳ねる（Review Focus 4 を改訂）。TTL 評価の tick を 30 秒から 5 秒にした（manual working 10 秒の維持のため）。いずれも spec 改訂の候補。
- Fable による計画レビュー（REVISE）を反映済み: Task 8 の結合確認手順の期待値、跳ねる判定の作り直し、時計の巻き戻り時の `lastAppliedTS`、`notification_type` の伏せ字、jitter 行数の自動判定、Fixtures 前提の明記、ほか。
