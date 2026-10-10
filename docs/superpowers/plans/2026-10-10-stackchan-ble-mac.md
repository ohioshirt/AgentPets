# StackChan BLE 出力（Mac 側）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** AgentPets が集約した表示状態（5 状態・StackChan 用の短い文・跳ねる番号）を、BLE の write without response で StackChan に送る。Mac が central、StackChan が peripheral。

**Architecture:** `AgentPetsCore` に純粋関数として `DisplayState.subtitle`（`Aggregator` が作る）と `StackChanRecord.encode`（wire 版 1 のバイト列）を足し、ファームウェアと共有するテストベクタを置く。アプリ側は `HubStore` を変えずに、`FanOutSink` で画面のペット（`PetViewModel`）と `StackChanSink` に同じ表示状態を配る。`StackChanSink` は跳ねる番号を数えて `RecordTransport` に渡し、実機の transport は CoreBluetooth central の `StackChanLink`（MainActor、`queue: nil`）。メニューに「StackChan に送る」のトグルと接続状態の 1 行を足す。

**Tech Stack:** Swift 6（Apple Swift 6.4 / Xcode 27.1 で確認）、SwiftPM、swift-testing、SwiftUI `MenuBarExtra`、CoreBluetooth、AppKit（`NSWorkspace`）、`os.Logger`。

**Spec:** `docs/superpowers/specs/2026-10-10-stackchan-ble-design.md`（commit 1f780c5）の §1（wire contract）と §2（Mac 側）。§3（ファームウェア）は別の計画で扱う。各タスクの実装者は spec の §1・§2 を読むこと。

## Global Constraints

- Service UUID は `B405CCEA-139A-4248-9CDE-5BAB2613D855`、State characteristic UUID は `24EE255E-42EC-4702-AF9C-C8EF325929AC`。書き込みは write without response のみ（read・notify は使わない）。
- レコードは版 `1`、状態 `0` idle / `1` working / `2` waiting / `3` success / `4` error、跳ねる番号は 0〜255 で一周（255 の次は 0）、文のバイト長 L は 1 バイト。全長は `min(maximumWriteValueLength(for: .withoutResponse), 259)` 以下。`maxLength < 4` なら送らない。
- 文は `Character` の切れ目で UTF-8 のバイト数に収め、切ったときは末尾を `…`（3 バイト）にする。`…` も入らないときは文を空にする。
- keep-alive は 5 秒。Timer は `RunLoop.main` の `.common` モードに登録する。characteristic を発見した直後と表示が変わったときは即時に送る。
- `CBCentralManager` は「StackChan に送る」を初めてオンにしたときに作る。トグルの既定はオフで、UserDefaults に保存する。connect・scan・retrieve は `.poweredOn` のときだけ行う。
- `FanOutSink` と `StackChanSink` はアプリ起動時に常設する。`HubStore` は変更しない。
- テストベクタ `Packages/AgentPetsCore/Tests/AgentPetsCoreTests/Fixtures/stackchan/state-record-v1.txt` はファームウェア計画が同じ書式で読む契約。書式（行の種類・欄・reason の語彙）を変えるときは実装を止めて親に上げる。
- テストは swift-testing（`import Testing`）。CoreBluetooth（`StackChanLink`）は自動テストしない（spec §2.3）。
- pbxproj は手で編集しない。ビルド設定は Xcode の Signing & Capabilities / Build Settings でユーザーが設定する。
- git の staging はパスを明示する（`git add <path>`）。`git add -A` / `git add .` は使わない。commit 前に `git status --porcelain` で無関係な変更が無いことを見る。
- macOS に `timeout` コマンドは無い。手順やスクリプトで使わない。
- テストやビルドの結果を報告するときは、実行したコマンドと生出力の末尾（10 行程度）を添える。ホストテストやビルド成功を実機確認の代わりにしない。実機の確認はユーザーと一緒に行い、`docs/superpowers/notes/2026-10-10-stackchan-ble-mac.md` に記録する。

## Review Focus

spec がはっきり書いていないが、使っていて最初に踏みそうな入力。各行のテストは担当タスクに入れてある。

1. **長い日本語の文**: `MessageText.limit` の 120 文字をすべて日本語にすると UTF-8 で 360 バイトになり、L（1 バイト）があふれる → `maxLength = 512` でも全長 259・L 255 に収まるべき（Task 2 `longJapanese`）。
2. **絵文字の修飾・結合文字**: `👍🏽` や `e` + U+0301 をスカラーの切れ目で切ると、UTF-8 としては正しいまま見た目だけ壊れ、ファームウェアの検証では気づけない → `Character` の切れ目で切るべき（Task 2 `emoji`・`combining`）。
3. **manual の idle に文を付けた送信**: `agentpets-notify.sh idle "休憩中"` → hook の idle と同じ扱いで文を空にすると、StackChan に何も出ない。manual は状態に関係なく文を送るべき（Task 1 `subtitleManualIdle`）。
4. **起動後にトグルをオンにする・送り先を後から付ける**: `HubStore` は同じ見た目を出し直さないので、送り先を付けた時点で値を渡さないと、状態が変わるまで StackChan に何も届かない → 付けた時点で最新の値と番号を渡すべき（Task 3 `keepsLatestWithoutTransport`）。
5. **Mac とファームウェアの解釈のずれ**: 片方だけ直すと黙って食い違う → 共有ベクタの accept 行は Swift の encode とバイト一致し、reject 行は書かれた理由で受信規則に落ちるべき（Task 2 `acceptRoundTrips`・`rejectsMatchReason`）。

---

## File Structure

| パス | 責務 |
|---|---|
| `Packages/AgentPetsCore/Sources/AgentPetsCore/Aggregator.swift` | `DisplayState.subtitle` の追加と、`Aggregator` での組み立て・`sameView` への追加（Task 1） |
| `Packages/AgentPetsCore/Sources/AgentPetsCore/StackChanRecord.swift` | wire 版 1 のレコード組み立てと文の切り詰め（Task 2） |
| `Packages/AgentPetsCore/Tests/AgentPetsCoreTests/AggregatorTests.swift` | `subtitle` のテストを追加（Task 1） |
| `Packages/AgentPetsCore/Tests/AgentPetsCoreTests/StackChanRecordTests.swift` | レコードの各バイトと切り詰めのテスト（Task 2） |
| `Packages/AgentPetsCore/Tests/AgentPetsCoreTests/StackChanVectorTests.swift` | 共有テストベクタの読み込みと検算（Task 2） |
| `Packages/AgentPetsCore/Tests/AgentPetsCoreTests/Fixtures/stackchan/state-record-v1.txt` | ファームウェアと共有する正のテストベクタ（Task 2） |
| `AgentPets/StackChanSink.swift` | `FanOutSink`、`protocol RecordTransport`、`StackChanSink`（Task 3） |
| `AgentPetsTests/StackChanSinkTests.swift` | `StackChanSink` と `FanOutSink` のテスト（Task 3） |
| `AgentPets/StackChanLink.swift` | CoreBluetooth central（Task 4） |
| `AgentPets/AgentPetsApp.swift` | `AppDelegate` の配線（Task 3・4）とメニュー項目（Task 4） |
| `AgentPets.xcodeproj/project.pbxproj` | Bluetooth のビルド設定（Task 4、ユーザーが Xcode で設定） |
| `docs/superpowers/notes/2026-10-10-stackchan-ble-mac.md` | 実機確認の記録（Task 5） |

`AgentPets/` と `AgentPetsTests/` はフォルダ同期グループ（`PBXFileSystemSynchronizedRootGroup`）なので、新しい `.swift` を置けばターゲットに入る。pbxproj を触る必要は無い。`Package.swift` の `resources: [.copy("Fixtures")]` は `Fixtures/` ごと複写するので、`Fixtures/stackchan/` を足しても `Package.swift` は変えない。

---

### Task 1: `DisplayState.subtitle`

**Files:**
- Modify: `Packages/AgentPetsCore/Sources/AgentPetsCore/Aggregator.swift`（全面置き換え）
- Test: `Packages/AgentPetsCore/Tests/AgentPetsCoreTests/AggregatorTests.swift`（`AggregatorTests` の末尾に追加）

**Interfaces:**
- Consumes: 既存の `SessionTable`、`SessionState`、`MessageText.sanitize`、`PetStatus.phrase`
- Produces:
  - `DisplayState.subtitle: String`
  - `DisplayState.init(status: PetStatus, message: String, tooltip: String = "", subtitle: String = "", sessionKey: SessionKey?, celebrate: Bool = false)`（`subtitle` は既定値つきで `tooltip` の後。既存の呼び出しはそのまま通る）
  - `DisplayState.sameView(as:)` は `subtitle` も比べる
  - 組み立て規則（spec §2.1）: hook は `<detail> · <project|source>`、detail が空なら `<project|source>`、hook の idle は空、manual は状態に関係なく `MessageText.sanitize(detail)`。どれも `MessageText.sanitize` を通す

- [ ] **Step 1: 失敗するテストを書く**

`Packages/AgentPetsCore/Tests/AgentPetsCoreTests/AggregatorTests.swift` の `struct AggregatorTests` の最後のテスト（`sameViewTooltip`）の後、構造体を閉じる `}` の前に追加する。ファイル先頭の `table` と `ev` をそのまま使う。

```swift

    // MARK: - subtitle（StackChan の文、spec §2.1）

    @Test("subtitle: hook は <detail> · <project>。状態の語は含めない")
    func subtitleDetailAndProject() {
        let d = Aggregator.display(table([ev(.inputRequested, 1, session: "a", project: "uwb", detail: "Bash")]))
        #expect(d.subtitle == "Bash · uwb")
    }

    @Test("subtitle: hook で detail が空なら project だけ")
    func subtitleProjectOnly() {
        let d = Aggregator.display(table([ev(.turnCompleted, 1, session: "a", project: "demo-project")]))
        #expect(d.subtitle == "demo-project")
    }

    @Test("subtitle: hook で project が空なら source")
    func subtitleSourceFallback() {
        let withDetail = Aggregator.display(table([ev(.activity, 1, session: "a", source: .codex, project: "", detail: "Edit")]))
        #expect(withDetail.subtitle == "Edit · codex")
        let bare = Aggregator.display(table([ev(.turnStarted, 1, session: "a", source: .codex, project: "")]))
        #expect(bare.subtitle == "codex")
    }

    @Test("subtitle: hook の idle は空")
    func subtitleHookIdle() {
        #expect(Aggregator.display(table([ev(.sessionStarted, 1, session: "a")])).subtitle == "")
        #expect(DisplayState.empty.subtitle == "")
    }

    @Test("subtitle: manual は送られた文そのもの")
    func subtitleManualWorking() {
        let d = Aggregator.display(table([ev(.turnStarted, 1, session: "manual", source: .manual, project: "", detail: "テスト実行中")]))
        #expect(d.subtitle == "テスト実行中")
    }

    @Test("subtitle: manual の idle でも文があれば送る（Review Focus 3）")
    func subtitleManualIdle() {
        // 旧形式の status=idle は turn.interrupted になる（WireCodec.legacyKind）
        let d = Aggregator.display(table([ev(.turnInterrupted, 1, session: "manual", source: .manual, project: "", detail: "休憩中")]))
        #expect(d.status == .idle)
        #expect(d.subtitle == "休憩中")
    }

    @Test("subtitle: 制御文字を畳み、120 文字で切り詰める")
    func subtitleSanitized() {
        let d = Aggregator.display(table([ev(.inputRequested, 1, session: "a", project: "a\nb",
                                             detail: String(repeating: "x", count: 200))]))
        #expect(!d.subtitle.contains("\n"))
        #expect(d.subtitle.count == MessageText.limit)
        #expect(d.subtitle.hasSuffix("…"))
    }

    @Test("sameView は subtitle が違えば false")
    func sameViewSubtitle() {
        let k = SessionKey(source: .claude, session: "a")
        let x = DisplayState(status: .working, message: "作業中 · p", tooltip: "t", subtitle: "Bash · p", sessionKey: k)
        let y = DisplayState(status: .working, message: "作業中 · p", tooltip: "t", subtitle: "Edit · p", sessionKey: k)
        #expect(!x.sameView(as: y))
        #expect(x.sameView(as: x))
    }
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test --package-path Packages/AgentPetsCore 2>&1 | tail -10`
Expected: コンパイルエラー（`value of type 'DisplayState' has no member 'subtitle'`、`extra argument 'subtitle' in call` など）。

- [ ] **Step 3: 実装を書く**

`Packages/AgentPetsCore/Sources/AgentPetsCore/Aggregator.swift` を次で置き換える（変更点: `subtitle` プロパティ・init 引数・`.empty`・`sameView`・`texts(for:)` の戻り値）。

```swift
import Foundation

/// 画面と（第 2 期の）BLE に出す 1 つの状態。
public struct DisplayState: Equatable, Sendable {
    public var status: PetStatus
    /// 吹き出しの文。狭い吹き出しでも状態語が切れないよう、状態を先頭に置く。
    public var message: String
    /// ホバー時に出す全文（`<source> · <project>: <状態>[ (<detail>)]`）。吹き出しが空なら空。
    public var tooltip: String
    /// StackChan に送る文（spec §2.1）。状態の語は含めない。hook は `<detail> · <project|source>`、manual は送られた文そのもの。
    public var subtitle: String
    public var sessionKey: SessionKey?
    /// 表示中セッションが今まさに turn.completed を受けた。跳ねる合図。
    /// 集約は立てない。HubStore.receive が、適用したイベントと表示中セッションが一致したときだけ立てる。
    public var celebrate: Bool

    public static let empty = DisplayState(status: .idle, message: "", tooltip: "", subtitle: "", sessionKey: nil, celebrate: false)

    public init(status: PetStatus, message: String, tooltip: String = "", subtitle: String = "",
                sessionKey: SessionKey?, celebrate: Bool = false) {
        self.status = status
        self.message = message
        self.tooltip = tooltip
        self.subtitle = subtitle
        self.sessionKey = sessionKey
        self.celebrate = celebrate
    }

    /// celebrate を除いて同じ見た目か。HubStore の重複排除に使う。
    public func sameView(as other: DisplayState) -> Bool {
        status == other.status && message == other.message && tooltip == other.tooltip
            && subtitle == other.subtitle && sessionKey == other.sessionKey
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
        let t = texts(for: top)
        return DisplayState(status: top.status, message: t.message, tooltip: t.tooltip, subtitle: t.subtitle,
                            sessionKey: top.key)
    }

    /// 吹き出しの文とツールチップ。吹き出しは `<状態>[ (<detail>)] · <project|source>`、
    /// ツールチップは `<source> · <project>: <状態>[ (<detail>)]`（project が空なら `<source>: …`）。
    /// StackChan の文は `<detail> · <project|source>`（detail が空なら `<project|source>`）。状態の語はファームウェアが出す。
    private static func texts(for state: SessionState) -> (message: String, tooltip: String, subtitle: String) {
        // manual は状態に関係なく送られた文を出す（idle でも文があれば StackChan に送る。spec §2.1）。
        if state.key.source == .manual {
            let text = MessageText.sanitize(state.detail)
            return (text, text, text)
        }
        guard state.status != .idle else { return ("", "", "") }
        let source = state.key.source.rawValue
        let place = state.project.isEmpty ? source : state.project
        let subtitle = state.detail.isEmpty ? place : "\(state.detail) · \(place)"
        let body = state.detail.isEmpty
            ? state.status.phrase
            : "\(state.status.phrase) (\(state.detail))"
        let bubble = "\(body) · \(place)"
        let full = state.project.isEmpty
            ? "\(source): \(body)"
            : "\(source) · \(state.project): \(body)"
        return (MessageText.sanitize(bubble), MessageText.sanitize(full), MessageText.sanitize(subtitle))
    }
}
```

- [ ] **Step 4: テストが通ることを確認**

Run: `swift test --package-path Packages/AgentPetsCore 2>&1 | tail -5`
Expected: 最終行が `Test run with N tests in M suites passed`。既存の `Aggregator` のテスト（`message`・`tooltip`）も変わらず通る。

- [ ] **Step 5: アプリ側が壊れていないことを確認**

`DisplayState.init` に既定値つき引数を足しただけなので、アプリのテスト（`AgentPetsTests/PetViewModelTests.swift:17` が `tooltip:` つきで呼ぶ）もそのまま通るはず。確かめる。

Run: `xcodebuild test -project AgentPets.xcodeproj -scheme AgentPets -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add Packages/AgentPetsCore/Sources/AgentPetsCore/Aggregator.swift Packages/AgentPetsCore/Tests/AgentPetsCoreTests/AggregatorTests.swift
git status --porcelain
git commit -m "Add a StackChan subtitle to the aggregated display state"
```

`git status --porcelain` に上の 2 ファイル以外が出たら、commit を止めて中身を確かめる。

---

### Task 2: `StackChanRecord.encode` と共有テストベクタ

**Files:**
- Create: `Packages/AgentPetsCore/Sources/AgentPetsCore/StackChanRecord.swift`
- Create: `Packages/AgentPetsCore/Tests/AgentPetsCoreTests/Fixtures/stackchan/state-record-v1.txt`
- Test: `Packages/AgentPetsCore/Tests/AgentPetsCoreTests/StackChanRecordTests.swift`（新規）, `Packages/AgentPetsCore/Tests/AgentPetsCoreTests/StackChanVectorTests.swift`（新規）

**Interfaces:**
- Consumes: Task 1 の `DisplayState.subtitle`、既存の `PetStatus`・`MessageText.limit`
- Produces:
  - `public enum StackChanRecord`
    - `static let version: UInt8 = 1`、`static let headerLength = 4`、`static let maxRecordLength = 259`
    - `static func statusByte(_ status: PetStatus) -> UInt8`
    - `static func encode(_ display: DisplayState, celebrateSeq: UInt8, maxLength: Int) -> Data?`
  - テストベクタの書式（ファームウェア計画との契約。1 行 1 ケース、hex は小文字・区切りなし）:
    - `#` で始まる行はコメント、空行は無視
    - `accept <レコードの hex> status=<0-4> seq=<0-255> text=<文の UTF-8 の hex。空なら ->`
    - `reject <レコードの hex> <reason>`、reason は `short` / `version` / `status` / `length` / `utf8` のいずれか。各 reject 行は規則を 1 つだけ破る

- [ ] **Step 1: 共有テストベクタを置く**

`Packages/AgentPetsCore/Tests/AgentPetsCoreTests/Fixtures/stackchan/state-record-v1.txt` を次の内容で作る（L=255 の行は 1 行が長いが、折り返さずに 1 行で書く）。

```text
# StackChan 状態レコード 版 1 のテストベクタ（spec §1.2・§1.3）。
# 正はこのファイル（AgentPets）。ファームウェア repo の tests/vectors/ はバイト一致のコピー。
# 書式（1 行 1 ケース。hex は小文字・区切りなし）:
#   accept <レコードの hex> status=<0-4> seq=<0-255> text=<文の UTF-8 の hex。空なら ->
#   reject <レコードの hex> <short|version|status|length|utf8>
# reject の各行は規則を 1 つだけ破る。# で始まる行と空行は無視する。

# 受理: 最小（idle・番号 0・文なし。L=0）
accept 01000000 status=0 seq=0 text=-
# 受理: 各状態
accept 0101010442617368 status=1 seq=1 text=42617368
accept 0102020b4261736820c2b720757762 status=2 seq=2 text=4261736820c2b720757762
accept 0103030c64656d6f2d70726f6a656374 status=3 seq=3 text=64656d6f2d70726f6a656374
accept 0104040e6275696c6420c2b720636f646578 status=4 seq=4 text=6275696c6420c2b720636f646578
# 受理: 番号 255、文なしの working（L=0）
accept 0103ff00 status=3 seq=255 text=-
accept 01010700 status=1 seq=7 text=-
# 受理: L=255（全長 259）。「あ」×85
accept 010210ffe38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182 status=2 seq=16 text=e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182e38182
# 受理: 日本語と「·」「…」
accept 01012a26e38386e382b9e38388e5ae9fe8a18ce4b8ad20c2b7207577622d737461636b6368616ee280a6 status=1 seq=42 text=e38386e382b9e38388e5ae9fe8a18ce4b8ad20c2b7207577622d737461636b6368616ee280a6
# 拒否: 全長 4 未満
reject 01 short
reject 010000 short
# 拒否: 版が 1 以外
reject 00000000 version
reject 02000000 version
# 拒否: 状態が範囲外
reject 01050000 status
reject 01ff0000 status
# 拒否: L が残りバイト数より大きい・小さい
reject 0100000261 length
reject 010000016162 length
reject 0100000061 length
reject 010000ff length
# 拒否: 不正な UTF-8（overlong、サロゲート、U+10FFFF 超、途中で切れた列、単独の継続バイト、0xff）
reject 01000002c080 utf8
reject 01000003eda080 utf8
reject 01000004f4908080 utf8
reject 01000002e381 utf8
reject 0100000180 utf8
reject 01000001ff utf8
```

内容の要点: accept は最小の idle（文なし・L=0）、各状態、番号 255、L=0 の working、L=255（全長 259、「あ」×85）、「·」と「…」を含む日本語。reject は全長 4 未満、版 0 と 2、状態 5 と 255、L が残りより大きい・小さい（L=0 で後ろにバイトがある場合を含む）、overlong（`c0 80`）、サロゲート（`ed a0 80`）、U+10FFFF 超（`f4 90 80 80`）、途中で切れた列（`e3 81`）、単独の継続バイト（`80`）、`ff`。

- [ ] **Step 2: 失敗するテストを書く**

`Packages/AgentPetsCore/Tests/AgentPetsCoreTests/StackChanRecordTests.swift`:

```swift
import Foundation
import Testing
@testable import AgentPetsCore

private func display(_ status: PetStatus, _ subtitle: String) -> DisplayState {
    DisplayState(status: status, message: "吹き出しは送らない", subtitle: subtitle, sessionKey: nil)
}

/// レコードの文の部分（4 バイト目以降）を文字列にする。
private func text(_ data: Data) -> String {
    String(decoding: data.dropFirst(StackChanRecord.headerLength), as: UTF8.self)
}

@Suite("StackChanRecord")
struct StackChanRecordTests {
    @Test("各バイト: 版 1・状態・番号・L・文。吹き出しの文（message）は送らない")
    func bytes() throws {
        let data = try #require(StackChanRecord.encode(display(.waiting, "Bash · uwb"), celebrateSeq: 7, maxLength: 512))
        // "Bash · uwb" は 11 バイト（「·」は U+00B7 で c2 b7）
        #expect(Array(data) == [1, 2, 7, 11] + Array("Bash · uwb".utf8))
    }

    @Test("状態値は idle 0 / working 1 / waiting 2 / success 3 / error 4")
    func statusBytes() throws {
        let expected: [(PetStatus, UInt8)] = [(.idle, 0), (.working, 1), (.waiting, 2), (.success, 3), (.error, 4)]
        for (status, byte) in expected {
            let data = try #require(StackChanRecord.encode(display(status, ""), celebrateSeq: 0, maxLength: 20))
            #expect(Array(data) == [1, byte, 0, 0])
        }
    }

    @Test("番号 255 はそのまま 1 バイトに入る")
    func seq255() throws {
        let data = try #require(StackChanRecord.encode(display(.success, ""), celebrateSeq: 255, maxLength: 20))
        #expect(data[2] == 255)
    }

    @Test("maxLength < 4 なら nil（負の値も）")
    func tooSmall() {
        #expect(StackChanRecord.encode(display(.idle, ""), celebrateSeq: 0, maxLength: 3) == nil)
        #expect(StackChanRecord.encode(display(.idle, ""), celebrateSeq: 0, maxLength: 0) == nil)
        #expect(StackChanRecord.encode(display(.idle, ""), celebrateSeq: 0, maxLength: -1) == nil)
    }

    @Test("ちょうど収まる文は切らない。1 バイト超えると … で終える")
    func exactFit() throws {
        let fits = try #require(StackChanRecord.encode(display(.working, "abcdefghijklmnop"), celebrateSeq: 0, maxLength: 20))
        #expect(fits.count == 20)
        #expect(text(fits) == "abcdefghijklmnop")

        let over = try #require(StackChanRecord.encode(display(.working, "abcdefghijklmnopq"), celebrateSeq: 0, maxLength: 20))
        #expect(over.count == 20)
        #expect(text(over) == "abcdefghijklm…")
        #expect(Int(over[3]) == over.count - 4)
    }

    @Test("マルチバイト: 文字の途中で切らない（最小 MTU の 20 バイト）")
    func multibyte() throws {
        // 「あ」は 3 バイト。16 バイトの枠で … を除く 13 バイトに 4 文字（12 バイト）
        let data = try #require(StackChanRecord.encode(display(.working, "あいうえおかきくけこ"), celebrateSeq: 0, maxLength: 20))
        #expect(text(data) == "あいうえ…")
        #expect(data.count == 19)
        #expect(Int(data[3]) == data.count - 4)
    }

    @Test("絵文字: 肌色修飾つきの 1 文字（8 バイト）を途中で切らない")
    func emoji() throws {
        // "👍🏽" は 1 Character・2 スカラー・8 バイト。文の枠 15 から … を除くと 12 バイトで、
        // スカラー単位で切ると "👍🏽👍"（12 バイト）が入って肌色修飾が外れる
        let data = try #require(StackChanRecord.encode(display(.working, "👍🏽👍🏽"), celebrateSeq: 0, maxLength: 4 + 15))
        #expect(text(data) == "👍🏽…")
        #expect(Int(data[3]) == 11)
    }

    @Test("結合文字: e + U+0301 を分けない")
    func combining() throws {
        // "é"（e + 結合アキュート）は 1 Character・3 バイト。枠 7、… を除く 4 バイトにスカラー単位なら "ée" が入る
        let data = try #require(StackChanRecord.encode(display(.working, "e\u{301}e\u{301}e\u{301}"), celebrateSeq: 0, maxLength: 4 + 7))
        #expect(Array(data.dropFirst(4)) == Array("e\u{301}…".utf8))
    }

    @Test("… も入らない極小の枠では文を空にする。収まる文はそのまま")
    func tinyLimits() throws {
        let four = try #require(StackChanRecord.encode(display(.error, "失敗の詳細"), celebrateSeq: 9, maxLength: 4))
        #expect(Array(four) == [1, 4, 9, 0])

        let six = try #require(StackChanRecord.encode(display(.error, "abc"), celebrateSeq: 9, maxLength: 6))
        #expect(Array(six) == [1, 4, 9, 0])

        let fitsInFive = try #require(StackChanRecord.encode(display(.error, "a"), celebrateSeq: 9, maxLength: 5))
        #expect(Array(fitsInFive) == [1, 4, 9, 1, 0x61])

        let onlyEllipsis = try #require(StackChanRecord.encode(display(.error, "abcd"), celebrateSeq: 9, maxLength: 7))
        #expect(text(onlyEllipsis) == "…")
    }

    @Test("maxLength = 512 で 120 文字の日本語: 全長 259 以下、L は実長と一致、正しい UTF-8")
    func longJapanese() throws {
        let long = MessageText.sanitize(String(repeating: "日本語の文", count: 30))
        #expect(long.count == MessageText.limit)
        let data = try #require(StackChanRecord.encode(display(.waiting, long), celebrateSeq: 1, maxLength: 512))
        #expect(data.count <= StackChanRecord.maxRecordLength)
        #expect(data.count == 259)
        #expect(Int(data[3]) == data.count - 4)
        let body = Array(data.dropFirst(4))
        #expect(String(validating: body, as: UTF8.self) != nil)
        #expect(text(data).hasSuffix("…"))
    }
}
```

`Packages/AgentPetsCore/Tests/AgentPetsCoreTests/StackChanVectorTests.swift`（`rejectReason` はベクタ自体の検算用で、受信規則の実装ではない。UTF-8 の判定は標準ライブラリに任せ、encode の実装とは独立させる）:

```swift
import Foundation
import Testing
@testable import AgentPetsCore

/// `Fixtures/stackchan/state-record-v1.txt` の 1 行。
private enum Vector {
    case accept(record: [UInt8], status: UInt8, seq: UInt8, text: [UInt8], line: Int)
    case reject(record: [UInt8], reason: String, line: Int)
}

private struct VectorFormatError: Error, CustomStringConvertible {
    let line: Int
    let why: String
    var description: String { "state-record-v1.txt:\(line): \(why)" }
}

private let rejectReasons: Set<String> = ["short", "version", "status", "length", "utf8"]

private func hex(_ s: Substring, line: Int) throws -> [UInt8] {
    guard s.count % 2 == 0, s.allSatisfy({ "0123456789abcdef".contains($0) }) else {
        throw VectorFormatError(line: line, why: "hex は小文字・偶数桁・区切りなし: \(s)")
    }
    var bytes: [UInt8] = []
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        bytes.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return bytes
}

private func field(_ s: Substring, _ name: String, line: Int) throws -> Substring {
    guard s.hasPrefix(name + "=") else { throw VectorFormatError(line: line, why: "\(name)= が無い: \(s)") }
    return s.dropFirst(name.count + 1)
}

private func loadVectors() throws -> [Vector] {
    let url = try #require(Bundle.module.url(forResource: "state-record-v1", withExtension: "txt",
                                              subdirectory: "Fixtures/stackchan"))
    let content = try String(contentsOf: url, encoding: .utf8)
    var vectors: [Vector] = []
    for (index, raw) in content.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        let line = index + 1
        if raw.isEmpty || raw.hasPrefix("#") { continue }
        let parts = raw.split(separator: " ", omittingEmptySubsequences: false)
        switch parts.first {
        case "accept":
            guard parts.count == 5 else { throw VectorFormatError(line: line, why: "accept は 5 欄") }
            let status = try field(parts[2], "status", line: line)
            let seq = try field(parts[3], "seq", line: line)
            let text = try field(parts[4], "text", line: line)
            guard let statusValue = UInt8(status), statusValue <= 4, let seqValue = UInt8(seq) else {
                throw VectorFormatError(line: line, why: "status は 0-4、seq は 0-255")
            }
            vectors.append(.accept(record: try hex(parts[1], line: line), status: statusValue, seq: seqValue,
                                   text: text == "-" ? [] : try hex(text, line: line), line: line))
        case "reject":
            guard parts.count == 3, rejectReasons.contains(String(parts[2])) else {
                throw VectorFormatError(line: line, why: "reject <hex> <short|version|status|length|utf8>")
            }
            vectors.append(.reject(record: try hex(parts[1], line: line), reason: String(parts[2]), line: line))
        default:
            throw VectorFormatError(line: line, why: "accept / reject / # 以外で始まる行")
        }
    }
    return vectors
}

/// spec §1.3 の受信規則を、ファームウェアと同じ順で判定する（ベクタ自体の検算用）。
/// UTF-8 の判定は標準ライブラリの `String(validating:as:)` に任せる。
private func rejectReason(_ r: [UInt8]) -> String? {
    if r.count < 4 { return "short" }
    if r[0] != 1 { return "version" }
    if r[1] > 4 { return "status" }
    if Int(r[3]) != r.count - 4 { return "length" }
    if String(validating: r.dropFirst(4), as: UTF8.self) == nil { return "utf8" }
    return nil
}

private let statuses: [PetStatus] = [.idle, .working, .waiting, .success, .error]

@Suite("StackChan テストベクタ（ファームウェアと共有）")
struct StackChanVectorTests {
    @Test("ファイルが読め、受理・拒否の各種が揃っている（空ファイルで素通りしない）")
    func coverage() throws {
        let vectors = try loadVectors()
        var acceptedStatuses = Set<UInt8>()
        var reasons = Set<String>()
        var lengths = Set<Int>()
        for v in vectors {
            switch v {
            case let .accept(record, status, _, text, _):
                acceptedStatuses.insert(status)
                lengths.insert(text.count)
                #expect(record.count == 4 + text.count)
            case let .reject(_, reason, _):
                reasons.insert(reason)
            }
        }
        #expect(acceptedStatuses == [0, 1, 2, 3, 4])
        #expect(reasons == rejectReasons)
        #expect(lengths.contains(0))
        #expect(lengths.contains(255))
    }

    @Test("accept の各行は Swift の encode と 1 バイトも違わない")
    func acceptRoundTrips() throws {
        for case let .accept(record, status, seq, text, line) in try loadVectors() {
            let subtitle = try #require(String(validating: text, as: UTF8.self), "line \(line)")
            let display = DisplayState(status: statuses[Int(status)], message: "", subtitle: subtitle, sessionKey: nil)
            let encoded = StackChanRecord.encode(display, celebrateSeq: seq, maxLength: StackChanRecord.maxRecordLength)
            #expect(encoded.map(Array.init) == record, "line \(line)")
            #expect(rejectReason(record) == nil, "line \(line)")
        }
    }

    @Test("reject の各行は、書かれた理由で受信規則に落ちる")
    func rejectsMatchReason() throws {
        for case let .reject(record, reason, line) in try loadVectors() {
            #expect(rejectReason(record) == reason, "line \(line)")
        }
    }
}
```

- [ ] **Step 3: テストが失敗することを確認**

Run: `swift test --package-path Packages/AgentPetsCore 2>&1 | tail -10`
Expected: コンパイルエラー（`cannot find 'StackChanRecord' in scope`）。

- [ ] **Step 4: 実装を書く**

`Packages/AgentPetsCore/Sources/AgentPetsCore/StackChanRecord.swift`:

```swift
import Foundation

/// StackChan へ送る状態レコード（wire 版 1）。spec §1.2。
///
/// | バイト | 内容 |
/// |---|---|
/// | 0 | 版（1） |
/// | 1 | 状態（0 idle / 1 working / 2 waiting / 3 success / 4 error） |
/// | 2 | 跳ねる番号（0〜255 で一周） |
/// | 3 | 文のバイト長 L（全長 − 4） |
/// | 4… | 文（UTF-8、`DisplayState.subtitle`） |
public enum StackChanRecord {
    public static let version: UInt8 = 1
    public static let headerLength = 4
    /// L が 1 バイトなので、全長は 4 + 255 = 259 を超えない。
    public static let maxRecordLength = 259
    static let ellipsis = Array("…".utf8)

    public static func statusByte(_ status: PetStatus) -> UInt8 {
        switch status {
        case .idle: return 0
        case .working: return 1
        case .waiting: return 2
        case .success: return 3
        case .error: return 4
        }
    }

    /// 全長は `min(maxLength, 259)` 以下。`maxLength < 4` なら nil。
    /// `maxLength` には `maximumWriteValueLength(for: .withoutResponse)` を渡す。
    public static func encode(_ display: DisplayState, celebrateSeq: UInt8, maxLength: Int) -> Data? {
        let cap = min(maxLength, maxRecordLength)
        guard cap >= headerLength else { return nil }
        let text = fit(display.subtitle, maxBytes: cap - headerLength)
        var data = Data([version, statusByte(display.status), celebrateSeq, UInt8(text.count)])
        data.append(contentsOf: text)
        return data
    }

    /// `Character` の切れ目で、UTF-8 が `maxBytes` に収まるよう切り詰める。
    /// 切ったときは末尾を `…`（3 バイト）にする。`…` すら入らないときは空にする。
    static func fit(_ text: String, maxBytes: Int) -> [UInt8] {
        let whole = Array(text.utf8)
        if whole.count <= maxBytes { return whole }
        guard maxBytes >= ellipsis.count else { return [] }
        let budget = maxBytes - ellipsis.count
        var kept: [UInt8] = []
        for character in text {
            let bytes = Array(String(character).utf8)
            if kept.count + bytes.count > budget { break }
            kept += bytes
        }
        return kept + ellipsis
    }
}
```

- [ ] **Step 5: テストが通ることを確認**

Run: `swift test --package-path Packages/AgentPetsCore 2>&1 | tail -5`
Expected: 最終行が `Test run with N tests in M suites passed`。`StackChanRecord` と `StackChan テストベクタ（ファームウェアと共有）` の両 suite が passed。

- [ ] **Step 6: 切り詰めのテストが効いていることを確かめる（一時的な変異、commit しない）**

`StackChanRecord.fit` の `for character in text {` を一時的に `for character in text.unicodeScalars {` に変えて実行し、`emoji` と `combining` が落ちることを見る。確認したら必ず元に戻し、`grep -n 'for character in text' Packages/AgentPetsCore/Sources/AgentPetsCore/StackChanRecord.swift` が `for character in text {` の 1 行だけを返すことを確かめる（ファイルは未 commit なので `git diff` では戻し忘れが見えない）。

```bash
swift test --package-path Packages/AgentPetsCore 2>&1 | grep -E "failed|passed after" | tail -6
```

Expected（変異中）: `結合文字: e + U+0301 を分けない` と `絵文字: 肌色修飾つきの 1 文字（8 バイト）を途中で切らない` が failed。戻した後に Step 5 をもう一度実行して全件 passed を確かめる。

- [ ] **Step 7: Commit**

```bash
git add Packages/AgentPetsCore/Sources/AgentPetsCore/StackChanRecord.swift Packages/AgentPetsCore/Tests/AgentPetsCoreTests/StackChanRecordTests.swift Packages/AgentPetsCore/Tests/AgentPetsCoreTests/StackChanVectorTests.swift Packages/AgentPetsCore/Tests/AgentPetsCoreTests/Fixtures/stackchan/state-record-v1.txt
git status --porcelain
git commit -m "Encode StackChan state records and share test vectors with the firmware"
```

---

### Task 3: `FanOutSink`・`StackChanSink`・`RecordTransport` と常設の配線

**Files:**
- Create: `AgentPets/StackChanSink.swift`
- Modify: `AgentPets/AgentPetsApp.swift`（`AppDelegate` の 2 箇所）
- Test: `AgentPetsTests/StackChanSinkTests.swift`（新規）

**Interfaces:**
- Consumes: 既存の `protocol DisplaySink: AnyObject { func show(_ display: DisplayState) }`（アプリモジュールは既定で MainActor）、`AgentPetsTests/HubStoreTests.swift` の `RecordingSink`（テストで再利用する。同名の型を新たに定義しない）
- Produces:
  - `final class FanOutSink: DisplaySink { init(_ sinks: [DisplaySink]) }`
  - `protocol RecordTransport: AnyObject { func send(display: DisplayState, celebrateSeq: UInt8) }`
  - `final class StackChanSink: DisplaySink { init(transport: RecordTransport? = nil); var transport: RecordTransport?; private(set) var latest: DisplayState; private(set) var celebrateSeq: UInt8 }`
    - `show` は `celebrate` のたびに `celebrateSeq &+= 1`（255 の次は 0）し、最新の値を transport に渡す
    - `transport` を付け替えた時点で、最新の値と番号を新しい transport に渡す
  - `AppDelegate` は `StackChanSink` を起動時から持ち、`HubStore(sink: FanOutSink([viewModel, stackChanSink]))` で配る（Task 4 が `stackChanSink.transport` に `StackChanLink` を付ける）

- [ ] **Step 1: 失敗するテストを書く**

`AgentPetsTests/StackChanSinkTests.swift`:

```swift
//
//  StackChanSinkTests.swift
//  AgentPetsTests
//

import AgentPetsCore
import Testing
@testable import AgentPets

@MainActor
final class FakeTransport: RecordTransport {
    var sent: [(display: DisplayState, celebrateSeq: UInt8)] = []
    func send(display: DisplayState, celebrateSeq: UInt8) { sent.append((display, celebrateSeq)) }
}

private func state(_ status: PetStatus, _ subtitle: String = "", celebrate: Bool = false) -> DisplayState {
    DisplayState(status: status, message: "", subtitle: subtitle, sessionKey: nil, celebrate: celebrate)
}

@Suite("StackChanSink")
@MainActor
struct StackChanSinkTests {
    @Test("celebrate のたびに番号が 1 増え、最新の表示状態と一緒に渡る")
    func incrementsOnCelebrate() {
        let transport = FakeTransport()
        let sink = StackChanSink(transport: transport)
        sink.show(state(.success, "demo", celebrate: true))
        sink.show(state(.success, "demo", celebrate: true))
        #expect(transport.sent.map(\.celebrateSeq).suffix(2) == [1, 2])
        #expect(transport.sent.last?.display.subtitle == "demo")
    }

    @Test("celebrate 無しでは番号は増えないが、表示状態は渡る")
    func noCelebrateKeepsSeq() {
        let transport = FakeTransport()
        let sink = StackChanSink(transport: transport)
        sink.show(state(.success, celebrate: true))
        sink.show(state(.working, "Bash · p"))
        sink.show(state(.success, "p"))
        #expect(transport.sent.map(\.celebrateSeq).suffix(3) == [1, 1, 1])
        #expect(transport.sent.last?.display.status == .success)
    }

    @Test("255 の次は 0")
    func wraps() {
        let transport = FakeTransport()
        let sink = StackChanSink(transport: transport)
        for _ in 0..<255 { sink.show(state(.success, celebrate: true)) }
        #expect(sink.celebrateSeq == 255)
        sink.show(state(.success, celebrate: true))
        #expect(sink.celebrateSeq == 0)
        #expect(transport.sent.last?.celebrateSeq == 0)
    }

    @Test("送り先が無い間も最新の値と番号を持ち続け、付けた時点で渡す")
    func keepsLatestWithoutTransport() {
        let sink = StackChanSink()
        sink.show(state(.success, "p", celebrate: true))
        sink.show(state(.waiting, "Bash · p"))
        let transport = FakeTransport()
        sink.transport = transport
        #expect(transport.sent.count == 1)
        #expect(transport.sent.first?.display.status == .waiting)
        #expect(transport.sent.first?.celebrateSeq == 1)
    }
}

@Suite("FanOutSink")
@MainActor
struct FanOutSinkTests {
    @Test("全 sink に同じ値が同じ順で届く")
    func deliversToAll() {
        // RecordingSink は HubStoreTests.swift で定義済み
        let a = RecordingSink()
        let b = RecordingSink()
        let fanOut = FanOutSink([a, b])
        let first = state(.working, "Bash · p")
        let second = state(.success, "p", celebrate: true)
        fanOut.show(first)
        fanOut.show(second)
        #expect(a.shown == [first, second])
        #expect(b.shown == [first, second])
    }
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `xcodebuild test -project AgentPets.xcodeproj -scheme AgentPets -destination 'platform=macOS' 2>&1 | tail -20`
Expected: コンパイルエラー（`cannot find type 'RecordTransport' in scope`、`cannot find 'StackChanSink' in scope` など）。

- [ ] **Step 3: 実装を書く**

`AgentPets/StackChanSink.swift`:

```swift
//
//  StackChanSink.swift
//  AgentPets
//

import AgentPetsCore

/// 複数の sink に同じ表示状態を配る。HubStore は 1 つの sink しか持たないので、ここで分ける。
final class FanOutSink: DisplaySink {
    private let sinks: [DisplaySink]

    init(_ sinks: [DisplaySink]) {
        self.sinks = sinks
    }

    func show(_ display: DisplayState) {
        for sink in sinks { sink.show(display) }
    }
}

/// StackChan へ最新の表示状態と跳ねる番号を渡す口。実機では StackChanLink、テストでは偽物。
protocol RecordTransport: AnyObject {
    func send(display: DisplayState, celebrateSeq: UInt8)
}

/// 跳ねる番号を数え、最新の表示状態と一緒に transport へ渡す。spec §2.2。
/// アプリ起動時から常設し、送り先の有無に関係なく最新の値を持ち続ける
/// （HubStore は同じ見た目を出し直さないので、後から作ると状態が変わるまで送る値が無くなる）。
final class StackChanSink: DisplaySink {
    private(set) var latest: DisplayState = .empty
    private(set) var celebrateSeq: UInt8 = 0

    /// 付け替えた時点で最新の値を渡す。
    var transport: RecordTransport? {
        didSet { transport?.send(display: latest, celebrateSeq: celebrateSeq) }
    }

    init(transport: RecordTransport? = nil) {
        self.transport = transport
    }

    func show(_ display: DisplayState) {
        // 255 の次は 0（spec §1.2）。
        if display.celebrate { celebrateSeq &+= 1 }
        latest = display
        transport?.send(display: latest, celebrateSeq: celebrateSeq)
    }
}
```

`AgentPets/AgentPetsApp.swift` の `AppDelegate` を 2 箇所変える。

プロパティ（`private var hub: HubStore?` の直後に追加）:

```swift
    private var hub: HubStore?
    /// トグルに関係なく常設し、最新の表示状態と跳ねる番号を持ち続ける（spec §2.2）。
    private let stackChanSink = StackChanSink()
```

`applicationDidFinishLaunching` の `HubStore` の生成:

```swift
        let hub = HubStore(sink: viewModel)
```

を次に変える。

```swift
        let hub = HubStore(sink: FanOutSink([viewModel, stackChanSink]))
```

- [ ] **Step 4: テストが通ることを確認**

Run: `xcodebuild test -project AgentPets.xcodeproj -scheme AgentPets -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`。`StackChanSink` と `FanOutSink` の suite を含む。

- [ ] **Step 5: Commit**

```bash
git add AgentPets/StackChanSink.swift AgentPets/AgentPetsApp.swift AgentPetsTests/StackChanSinkTests.swift
git status --porcelain
git commit -m "Fan the display state out to a StackChan sink that counts celebrations"
```

---

### Task 4: `StackChanLink`（CoreBluetooth central）とメニュー

CoreBluetooth は自動テストしない（spec §2.3）。このタスクのゲートはビルド・既存テスト・ビルド設定の確認まで。接続の挙動は Task 5 で実機確認する。

**Files:**
- Create: `AgentPets/StackChanLink.swift`
- Modify: `AgentPets/AgentPetsApp.swift`（全面置き換え。メニュー項目と `AppDelegate` の配線）
- Modify: `AgentPets.xcodeproj/project.pbxproj`（Step 1 でユーザーが Xcode の UI から変更する。手で編集しない）

**Interfaces:**
- Consumes: Task 2 の `StackChanRecord.encode`、Task 3 の `RecordTransport`・`StackChanSink.transport`
- Produces:
  - `@Observable final class StackChanLink: NSObject, RecordTransport, CBCentralManagerDelegate, CBPeripheralDelegate`
    - `init(defaults: UserDefaults = .standard)`、`func start()`（起動時に 1 回）、`func setEnabled(_ enabled: Bool)`
    - `private(set) var isEnabled: Bool`（UserDefaults `StackChanLink.enabled`、既定 false）
    - `private(set) var status: Status`。`Status` は `.off` / `.poweredOff` / `.unauthorized` / `.unsupported` / `.searching` / `.connected(name:identifier:)`、`label` がメニューの 1 行
    - 覚えた identifier は UserDefaults `StackChanLink.peripheralIdentifier`
  - メニュー: `Toggle("StackChan に送る")` と `Text(link.status.label)`
  - ログ: subsystem `AgentPets`、category `StackChan`（Task 5 が `log stream` で読む）

動作の要点（spec §1.1・§1.4・§2.2 との対応）:

| 契機 | 動作 |
|---|---|
| トグルをオン | `CBCentralManager(delegate: self, queue: nil)` を初めて作る。作成済みなら現在の state で判定し直す |
| `centralManagerDidUpdateState` が `.poweredOn` | §1.1 をやり直す: 保留・接続中を取り消し、覚えた identifier を `retrievePeripherals(withIdentifiers:)` で取り出して `connect`、同時に Service UUID で `scanForPeripherals` |
| `.poweredOff` / `.unauthorized` / `.unsupported` | 参照を捨ててメニューに出すだけ（ペット表示は止めない） |
| スキャンで発見 | 最初の 1 台だけ `connect`（`stopScan`）。保留中の候補と同じ identifier なら何もしない |
| `didConnect` | 先につながった方を使い、他の候補を `cancelPeripheralConnection`。service → characteristic を発見 |
| characteristic を発見 | identifier を保存、メニューを「接続中」、すぐ 1 回送り、5 秒の keep-alive（`.common`）を始める |
| 表示の変化（`send`） | 最新の 1 件を置き換えて、送れるならすぐ送る |
| 送る直前 | `maximumWriteValueLength(for: .withoutResponse)` を読んで `StackChanRecord.encode`。`canSendWriteWithoutResponse` が false なら `peripheralIsReady(toSendWriteWithoutResponse:)` まで待って最新を送る |
| 切断（使用中の機体） | §1.1 をやり直す |
| `didFailToConnect` | その候補を外し、候補が尽きたらスキャンだけ再開する |
| `NSWorkspace.didWakeNotification` | §1.1 をやり直す（`.poweredOn` のときのみ） |
| トグルをオフ | 保留中・接続中を `cancelPeripheralConnection`、`stopScan`、keep-alive を止める。central は残す |

- [ ] **Step 1: Bluetooth のビルド設定（ユーザーの手作業）**

ユーザーに依頼する。pbxproj は手で編集しない。

1. Xcode で `AgentPets.xcodeproj` を開き、TARGETS の `AgentPets` を選ぶ。
2. Signing & Capabilities の App Sandbox で、Hardware の **Bluetooth** にチェックを入れる。これで `ENABLE_RESOURCE_ACCESS_BLUETOOTH = YES` が Debug・Release の両方に入る想定（入ったかは下の grep で確かめる）。チェック欄が見当たらない場合は、Build Settings（All・Combined）で「Bluetooth」を検索し、App Sandbox & Hardened Runtime の Bluetooth を Debug・Release とも Yes にする。
3. Build Settings で「Privacy - Bluetooth Always Usage Description」（`INFOPLIST_KEY_NSBluetoothAlwaysUsageDescription`）を検索し、Debug・Release とも次の文にする: `机の上の StackChan に AgentPets の状態を表示するために Bluetooth を使います。`

完了後に確認する:

```bash
grep -n 'ENABLE_RESOURCE_ACCESS_BLUETOOTH\|INFOPLIST_KEY_NSBluetoothAlwaysUsageDescription' AgentPets.xcodeproj/project.pbxproj
git diff --stat
```

Expected: `ENABLE_RESOURCE_ACCESS_BLUETOOTH = YES;` が 2 行、`INFOPLIST_KEY_NSBluetoothAlwaysUsageDescription = "机の上の StackChan に…";` が 2 行（`AgentPets` ターゲットの Debug と Release。`AgentPetsTests` には不要）。`git diff --stat` は `AgentPets.xcodeproj/project.pbxproj` だけ。`AgentPets/AgentPets.entitlements` も変わっていたら、差分が `com.apple.security.device.bluetooth` の追加だけであることを確かめ、Step 7 の `git add` に含める。

- [ ] **Step 2: `StackChanLink` を書く**

`AgentPets/StackChanLink.swift`:

```swift
//
//  StackChanLink.swift
//  AgentPets
//

import AgentPetsCore
import AppKit
import CoreBluetooth
import Observation
import os

/// 実機確認（Task 5）で `log stream --predicate 'subsystem == "AgentPets"'` から読む。
nonisolated private let log = Logger(subsystem: "AgentPets", category: "StackChan")

/// StackChan との BLE 接続（Mac が central）。spec §1.1・§1.4・§2.2。
///
/// delegate はメインキュー（`queue: nil`）で届く。クラスはモジュール既定の MainActor 隔離で、
/// delegate への準拠は MainActor の isolated conformance になる。実行時チェックで落ちる場合は、
/// delegate メソッドを `nonisolated` にして `MainActor.assumeIsolated` で中に入る（spec §2.2、Task 5 で確認）。
@Observable
final class StackChanLink: NSObject, RecordTransport {
    enum Status: Equatable {
        case off
        case poweredOff
        case unauthorized
        case unsupported
        case searching
        case connected(name: String, identifier: UUID)

        var label: String {
            switch self {
            case .off: return "StackChan: 未使用"
            case .poweredOff: return "StackChan: Bluetooth オフ"
            case .unauthorized: return "StackChan: 許可されていません"
            case .unsupported: return "StackChan: Bluetooth を使えません"
            case .searching: return "StackChan: 探しています"
            case let .connected(name, identifier): return "StackChan: 接続中 \(name) (\(identifier.uuidString))"
            }
        }
    }

    static let serviceUUID = CBUUID(string: "B405CCEA-139A-4248-9CDE-5BAB2613D855")
    static let stateCharacteristicUUID = CBUUID(string: "24EE255E-42EC-4702-AF9C-C8EF325929AC")
    static let keepAliveInterval: TimeInterval = 5
    static let enabledKey = "StackChanLink.enabled"
    static let identifierKey = "StackChanLink.peripheralIdentifier"

    private(set) var status: Status = .off
    private(set) var isEnabled: Bool

    @ObservationIgnored private let defaults: UserDefaults
    /// 「StackChan に送る」を初めてオンにしたときに作る（使わない人に許可ダイアログを出さないため）。
    @ObservationIgnored private var central: CBCentralManager?
    /// connect を保留中の候補（覚えた機体とスキャンで見つけた機体）。先につながった方を使う。
    @ObservationIgnored private var candidates: [CBPeripheral] = []
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var characteristic: CBCharacteristic?
    @ObservationIgnored private var latest = (display: DisplayState.empty, celebrateSeq: UInt8(0))
    /// `canSendWriteWithoutResponse` が false で送れなかった。`peripheralIsReady` で最新を送る。
    @ObservationIgnored private var writePending = false
    @ObservationIgnored private var keepAlive: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
        super.init()
    }

    /// アプリ起動時に 1 回呼ぶ。保存されたトグルがオンなら central を作る。
    func start() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            log.notice("didWake: redo discovery")
            MainActor.assumeIsolated { self?.restartDiscovery() }
        }
        if isEnabled { startCentral() }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled {
            startCentral()
        } else {
            dropConnection()
            status = .off
        }
    }

    // MARK: - RecordTransport

    func send(display: DisplayState, celebrateSeq: UInt8) {
        latest = (display, celebrateSeq)
        sendLatest()
    }

    // MARK: - 接続の手順

    private func startCentral() {
        if let central {
            apply(central.state)
        } else {
            status = .searching
            // 状態は centralManagerDidUpdateState で届く。ここでは scan も connect もしない。
            central = CBCentralManager(delegate: self, queue: nil)
        }
    }

    private func apply(_ state: CBManagerState) {
        log.notice("central state=\(state.rawValue, privacy: .public) enabled=\(self.isEnabled, privacy: .public)")
        guard isEnabled else { return }
        switch state {
        case .poweredOn:
            restartDiscovery()
        case .poweredOff:
            // 電源を切ると接続は切れ、CBPeripheral は無効になる。参照だけ捨てる。
            dropConnection()
            status = .poweredOff
        case .unauthorized:
            dropConnection()
            status = .unauthorized
        case .unsupported:
            dropConnection()
            status = .unsupported
        case .unknown, .resetting:
            dropConnection()
            status = .searching
        @unknown default:
            dropConnection()
            status = .searching
        }
    }

    /// spec §1.1: 覚えた機体の retrieve と Service UUID のスキャンを並行させ、先につながった方を使う。
    private func restartDiscovery() {
        guard isEnabled, let central, central.state == .poweredOn else { return }
        dropConnection()
        status = .searching
        if let saved = defaults.string(forKey: Self.identifierKey), let identifier = UUID(uuidString: saved),
           let known = central.retrievePeripherals(withIdentifiers: [identifier]).first {
            candidates.append(known)
            central.connect(known, options: nil)
        }
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
    }

    /// 保留中・接続中の peripheral を取り消し、スキャンと keep-alive を止める。
    /// API の誤用警告を避けるため、取り消しは `.poweredOn` のときだけ行う。
    private func dropConnection() {
        stopKeepAlive()
        if let central, central.state == .poweredOn {
            central.stopScan()
            for candidate in candidates { central.cancelPeripheralConnection(candidate) }
            if let peripheral { central.cancelPeripheralConnection(peripheral) }
        }
        candidates = []
        peripheral = nil
        characteristic = nil
        writePending = false
    }

    // MARK: - 送信（spec §1.4）

    private func sendLatest() {
        guard let peripheral, let characteristic, peripheral.state == .connected else { return }
        guard peripheral.canSendWriteWithoutResponse else {
            writePending = true
            return
        }
        writePending = false
        let maxLength = peripheral.maximumWriteValueLength(for: .withoutResponse)
        guard let record = StackChanRecord.encode(latest.display, celebrateSeq: latest.celebrateSeq,
                                                  maxLength: maxLength) else { return }
        peripheral.writeValue(record, for: characteristic, type: .withoutResponse)
        log.debug("write \(record.map { String(format: "%02x", $0) }.joined(), privacy: .public)")
    }

    /// .common モードに入れないと、メニューを開いている間 keep-alive が止まる（HubStore.start と同じ理由）。
    private func startKeepAlive() {
        stopKeepAlive()
        let timer = Timer(timeInterval: Self.keepAliveInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sendLatest() }
        }
        RunLoop.main.add(timer, forMode: .common)
        keepAlive = timer
    }

    private func stopKeepAlive() {
        keepAlive?.invalidate()
        keepAlive = nil
    }
}

extension StackChanLink: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        apply(central.state)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.peripheral == nil else { return }
        // 複数見つかっても最初の 1 台だけを使う（spec §1.1）。
        central.stopScan()
        guard !candidates.contains(where: { $0.identifier == peripheral.identifier }) else { return }
        candidates.append(peripheral)
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.peripheral == nil, candidates.contains(where: { $0 === peripheral }) else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        central.stopScan()
        for other in candidates where other !== peripheral { central.cancelPeripheralConnection(other) }
        candidates = []
        self.peripheral = peripheral
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        candidates.removeAll { $0 === peripheral }
        // 候補が尽きたらスキャンだけ再開する（retrieve をやり直すと、失敗を繰り返す機体で回り続けるため）。
        if self.peripheral == nil, candidates.isEmpty, isEnabled, central.state == .poweredOn {
            central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: (any Error)?) {
        log.notice("didDisconnect \(peripheral.identifier.uuidString, privacy: .public) error=\(String(describing: error), privacy: .public)")
        // 自分で取り消した接続（トグルのオフ、やり直し）は self.peripheral を先に捨てているので、ここで止まる。
        guard peripheral === self.peripheral else { return }
        self.peripheral = nil
        characteristic = nil
        restartDiscovery()
    }
}

extension StackChanLink: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard peripheral === self.peripheral else { return }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            // 期待した service が無い。切断の通知で §1.1 をやり直す。
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([Self.stateCharacteristicUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: (any Error)?) {
        guard peripheral === self.peripheral else { return }
        guard let found = service.characteristics?.first(where: { $0.uuid == Self.stateCharacteristicUUID }) else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        characteristic = found
        let maxLength = peripheral.maximumWriteValueLength(for: .withoutResponse)
        log.notice("ready \(peripheral.name ?? "-", privacy: .public) \(peripheral.identifier.uuidString, privacy: .public) maximumWriteValueLength(.withoutResponse)=\(maxLength, privacy: .public)")
        defaults.set(peripheral.identifier.uuidString, forKey: Self.identifierKey)
        status = .connected(name: peripheral.name ?? "（名前なし）", identifier: peripheral.identifier)
        // 発見の直後に 1 回、以後 5 秒ごと（spec §1.4）。
        sendLatest()
        startKeepAlive()
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard peripheral === self.peripheral,
              invalidatedServices.contains(where: { $0.uuid == Self.serviceUUID }) else { return }
        characteristic = nil
        stopKeepAlive()
        status = .searching
        peripheral.discoverServices([Self.serviceUUID])
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard peripheral === self.peripheral, writePending else { return }
        sendLatest()
    }
}
```

- [ ] **Step 3: 配線とメニューを書く**

`AgentPets/AgentPetsApp.swift` を次で置き換える（Task 3 からの変更点: メニューの「サイズを既定に戻す」の前にトグルと状態の行、`AppDelegate` に `stackChanLink` と、その `start()` と `stackChanSink.transport` への接続）。

```swift
//
//  AgentPetsApp.swift
//  AgentPets
//

import SwiftUI

@main
struct AgentPetsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Pet", systemImage: "pawprint.fill") {
            let library = appDelegate.library

            if library.pets.isEmpty {
                Text(library.isFolderMissing ? "ペットフォルダが見つかりません" : "ペットが未設定です")
            } else {
                ForEach(library.pets) { pet in
                    Button {
                        library.select(pet)
                    } label: {
                        Text(library.selection?.id == pet.id ? "✓ \(pet.displayName)" : pet.displayName)
                    }
                }
                Divider()
                Button("絵文字で表示") { library.select(nil) }
            }

            Divider()
            Button(library.folderURL == nil ? "ペットフォルダを選択…" : "ペットフォルダを変更…") {
                chooseFolder(for: library)
            }

            Divider()
            let link = appDelegate.stackChanLink
            Toggle("StackChan に送る", isOn: Binding(get: { link.isEnabled }, set: { link.setEnabled($0) }))
            Text(link.status.label)

            Divider()
            Button("サイズを既定に戻す") { appDelegate.windowController?.resetSize() }

            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }

    /// メニュートラッキング中に直接モーダルを出すと、パネルが裏に回ることがある。
    /// アクティブ化してから次の RunLoop に回す。
    private func chooseFolder(for library: PetLibrary) {
        DispatchQueue.main.async {
            NSApp.activate()

            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.showsHiddenFiles = true
            panel.prompt = "選択"
            panel.message = "ペットパッケージが入っているフォルダを選んでください。"

            guard panel.runModal() == .OK, let url = panel.url else { return }
            library.setFolder(url)
        }
    }
}

/// ペットのウィンドウと通知リスナーはアプリと同じ寿命で生きる必要がある。
/// Scene の body 評価中に `@State` へ書き戻すやり方では参照が保持されず、
/// リスナーが即座に解放されて購読が外れるため、delegate 側で所有する。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let viewModel = PetViewModel()
    let library = PetLibrary()
    private(set) var windowController: FloatingWindowController?
    private var listener: StatusNotificationListener?
    private var hub: HubStore?
    let stackChanLink = StackChanLink()
    /// トグルに関係なく常設し、最新の表示状態と跳ねる番号を持ち続ける（spec §2.2）。
    private let stackChanSink = StackChanSink()

    func applicationDidFinishLaunching(_ notification: Notification) {
        library.restore()

        let controller = FloatingWindowController(
            rootView: ContentView(viewModel: viewModel, library: library)
        )
        controller.showWindow(nil)
        windowController = controller

        stackChanSink.transport = stackChanLink
        stackChanLink.start()

        let hub = HubStore(sink: FanOutSink([viewModel, stackChanSink]))
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

- [ ] **Step 4: ビルドと既存テスト**

Run:

```bash
xcodebuild build -project AgentPets.xcodeproj -scheme AgentPets -configuration Debug -destination 'platform=macOS' > "$TMPDIR/agentpets-build.log" 2>&1; tail -3 "$TMPDIR/agentpets-build.log"
grep -E "warning:|error:" "$TMPDIR/agentpets-build.log" | grep -i stackchan
xcodebuild test -project AgentPets.xcodeproj -scheme AgentPets -destination 'platform=macOS' 2>&1 | tail -5
swift test --package-path Packages/AgentPetsCore 2>&1 | tail -5
```

Expected: `StackChan` を含む warning・error が 0 行、`** BUILD SUCCEEDED **`、`** TEST SUCCEEDED **`、コアは `Test run with N tests in M suites passed`。

- [ ] **Step 5: 成果物に権限と説明文が入っていることを確認**

```bash
APP_DIR="$(xcodebuild -project AgentPets.xcodeproj -scheme AgentPets -configuration Debug -showBuildSettings 2>/dev/null | awk '$1 == "BUILT_PRODUCTS_DIR" {print $3; exit}')"
echo "$APP_DIR"
codesign -d --entitlements - "$APP_DIR/AgentPets.app" 2>&1 | grep -n 'bluetooth\|app-sandbox'
plutil -p "$APP_DIR/AgentPets.app/Contents/Info.plist" | grep NSBluetoothAlwaysUsageDescription
```

Expected: `com.apple.security.device.bluetooth` と `com.apple.security.app-sandbox` が出る。`NSBluetoothAlwaysUsageDescription` に Step 1 の文が出る。`com.apple.security.device.bluetooth` が出なければ、sandbox のアプリは Bluetooth を使えない。commit せずにユーザーへ Step 1 の設定を見直してもらう。

- [ ] **Step 6: 起動時に許可ダイアログを出さないことの確認（トグルはオフのまま）**

ユーザーに依頼する: ビルドしたアプリを起動し、メニューに「StackChan に送る」（チェックなし）と「StackChan: 未使用」が出ること、Bluetooth の許可ダイアログが出ないことを見てもらう。トグルはまだオンにしない（Task 5 で行う）。結果は Task 5 の記録に書く。

- [ ] **Step 7: Commit**

```bash
git add AgentPets/StackChanLink.swift AgentPets/AgentPetsApp.swift AgentPets.xcodeproj/project.pbxproj
git status --porcelain
git commit -m "Send display records to StackChan over BLE from a menu toggle"
```

Step 1 で `AgentPets/AgentPets.entitlements` が変わっていた場合は、`git add` にそのパスも加える。`git status --porcelain` にそれ以外が出たら commit を止める。

---

### Task 5: 実機確認（ユーザーと一緒に行う）

ホストテストとビルドの成功は、ここでの確認の代わりにならない。操作はユーザーが行い、実装者は手順の提示と記録をする。spec §5 の未検証事項のうち Mac 側の 4 つ（実際の `maximumWriteValueLength`、LSUIElement アプリでの許可ダイアログ、スリープ復帰、delegate の isolated conformance の実行時チェック）に答える。

**Files:**
- Create: `docs/superpowers/notes/2026-10-10-stackchan-ble-mac.md`

**相手の peripheral について:** 本命は第 3 期のファームウェアを書き込んだ StackChan（別計画）。ファームウェアより先に Mac 側だけを確かめたい場合、iPhone の BLE peripheral シミュレータアプリ（サードパーティ製）で、Service `B405CCEA-139A-4248-9CDE-5BAB2613D855` と、プロパティが write without response の Characteristic `24EE255E-42EC-4702-AF9C-C8EF325929AC` を公開する方法もある。サードパーティ製アプリを入れるかどうか、どれを使うかはユーザーが決める。実装者は入れることを勧めたり、自分で入れたりしない。Mac は名前で絞らないので、シミュレータのデバイス名が `StackChanPet` でなくてもつながる。シミュレータでの確認は「Mac 側の挙動」の記録であり、StackChan での結合確認の代わりにはしない。記録にはどちらの相手で確かめたかを必ず書く。

- [ ] **Step 1: 記録ファイルを作る**

`docs/superpowers/notes/2026-10-10-stackchan-ble-mac.md`:

```markdown
# StackChan BLE（Mac 側）実機確認

- 日時:
- AgentPets の commit:
- macOS / Mac の機種:
- 相手: StackChan（ファームウェアの commit: ） / iPhone のシミュレータ（アプリ名・版: ）

## 1. 許可ダイアログ（spec §5「LSUIElement アプリでの Bluetooth 許可ダイアログの出方」）

- トグルがオフの起動で、ダイアログが出なかったか:
- 初めてトグルをオンにしたときのダイアログの出方（前面に出たか、メニューの裏に隠れたか）:
- 「許可しない」を選んだときのメニューの行:
- 許可した後のメニューの行:

## 2. 接続と実際の書き込み上限（spec §5「macOS の実際の maximumWriteValueLength」）

- `ready …` ログの行（そのまま貼る）:
- maximumWriteValueLength(.withoutResponse) の値:
- メニューの行（名前と identifier）:

## 3. 送信（成功条件 1・2）

| 操作 | `write …` ログの hex | 相手側で見えた値・表示 | 変化から届くまで |
|---|---|---|---|
| `agentpets-notify.sh working "テスト実行中"` | | | |
| `agentpets-notify.sh success "完了テスト"` | | | |
| もう一度 `agentpets-notify.sh success "完了テスト"` | | | |
| メニューを開いたまま 15 秒 | | | |

## 4. 切断・Bluetooth オフ・スリープ復帰（spec §5「スリープ復帰時の CoreBluetooth の挙動」）

- 相手の電源を切った（シミュレータは公開を止めた）ときのメニューの行と `didDisconnect` ログ:
- 相手を戻したときの再接続（同じ identifier か）:
- コントロールセンターで Bluetooth をオフ → オン:
- スリープ → 復帰（`didWake` ログ、再接続までの時間）:
- トグルをオフにしたとき（`write` ログが止まるか、相手側が切断を見たか）:

## 5. delegate の隔離（spec §5「isolated conformance の実行時チェック」）

- 上の操作の間にアプリが落ちなかったか:
- `~/Library/DiagnosticReports/` に `AgentPets` のクラッシュレポートが増えていないか:

## 気づいたこと
```

- [ ] **Step 2: ログを流しながらトグルをオンにする**

ユーザーに依頼する。別のターミナルで:

```bash
log stream --predicate 'subsystem == "AgentPets"' --level debug
```

相手（StackChan かシミュレータ）を advertise させた状態でメニューの「StackChan に送る」をオンにし、許可ダイアログの出方を見てもらう。以前に許可済みならダイアログは出ないので、そのことを記録する。

Expected: `central state=5`（`.poweredOn`）、続いて `ready <名前> <identifier> maximumWriteValueLength(.withoutResponse)=<値>` と `write 01…` のログ。メニューは「StackChan: 接続中 <名前> (<identifier>)」。値を記録 §2 に写す。

- [ ] **Step 3: 送信と跳ねる番号を見る**

```bash
./scripts/agentpets-notify.sh working "テスト実行中"
./scripts/agentpets-notify.sh success "完了テスト"
./scripts/agentpets-notify.sh success "完了テスト"
```

Expected: `write 0101<番号>12e38386e382b9e38388e5ae9fe8a18ce4b8ad`（working・「テスト実行中」は 18 バイト = `0x12`）。success を送るたびに 3 バイト目（番号）が 1 増える。何も送らずにいると 5 秒ごとに同じ hex が出る。メニューを開いたままでも 5 秒ごとに出ること（`.common` モード）を見る。結果を記録 §3 に写す。

- [ ] **Step 4: 切断・Bluetooth オフ・スリープ復帰・トグルのオフ**

記録 §4 の項目を順に行ってもらう。スリープはアップルメニューの「スリープ」か `pmset sleepnow`（ユーザーが実行する）。

Expected: 切断で「StackChan: 探しています」に戻り、相手が戻ると同じ identifier で再接続する。Bluetooth オフで「StackChan: Bluetooth オフ」、オンで再接続。復帰で `didWake: redo discovery` の後に再接続。トグルのオフで `write` ログが止まり、メニューは「StackChan: 未使用」。

- [ ] **Step 5: delegate の隔離を確かめる**

Step 2〜4 の間にアプリが落ちていないこと、`ls -t ~/Library/DiagnosticReports/ | grep -i agentpets | head` に新しいレポートが無いことを確かめる。記録 §5 に書く。

落ちていた場合（`Incorrect actor executor assumption` などの隔離の実行時チェック）は、実装を止めて親に報告する。親の判断で行う修正は spec §2.2 の代替案で、`StackChanLink.swift` の 2 つの delegate extension を次に置き換え、元の各メソッドの本体を `StackChanLink` の MainActor メソッド（`handleUpdateState(_:)`、`handleDiscover(_:_:)`、`handleConnect(_:_:)`、`handleFailToConnect(_:_:)`、`handleDisconnect(_:_:reason:)`、`handleDiscoverServices(_:)`、`handleDiscoverCharacteristics(_:_:)`、`handleModifyServices(_:_:)`、`handleReadyToSend(_:)`）へ移す。`handleDisconnect` は `didDisconnect` のログに `reason` を使う。

```swift
extension StackChanLink: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated { handleUpdateState(central) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated { handleDiscover(central, peripheral) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { handleConnect(central, peripheral) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                                    error: (any Error)?) {
        MainActor.assumeIsolated { handleFailToConnect(central, peripheral) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: (any Error)?) {
        let reason = String(describing: error)
        MainActor.assumeIsolated { handleDisconnect(central, peripheral, reason: reason) }
    }
}

extension StackChanLink: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        MainActor.assumeIsolated { handleDiscoverServices(peripheral) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                error: (any Error)?) {
        MainActor.assumeIsolated { handleDiscoverCharacteristics(peripheral, service) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        MainActor.assumeIsolated { handleModifyServices(peripheral, invalidatedServices) }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        MainActor.assumeIsolated { handleReadyToSend(peripheral) }
    }
}
```

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/notes/2026-10-10-stackchan-ble-mac.md
git status --porcelain
git commit -m "Record the StackChan BLE check on the Mac side"
```
