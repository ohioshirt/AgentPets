# スプライトアニメーション対応 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ペットの表示を固定の絵文字から、ユーザーが選んだフォルダにあるスプライトアトラスの
アニメーションに置き換える。

**Architecture:** `pet.json` を読む層（`PetManifest`）、アトラスをフレームに切る層（`SpriteSheet`）、
状態からクリップを決める層（`PetAnimation` / `AnimationClip`）、再生する層（`PetAnimator`）、
描く層（`PetSpriteView`）に分ける。フレーム番号の決定は時計に依存しない純粋関数にして、
`Timer` はそれを叩くだけの駆動役にする。通信仕様（`StatusPayload`）は変更しない。

**Tech Stack:** Swift 6.0 / SwiftUI + AppKit / ImageIO / Swift Testing / Xcode 27

**Spec:** `docs/design/2026-08-15-sprite-animation-design.md`

## Global Constraints

- macOS 26.0 以降。`MACOSX_DEPLOYMENT_TARGET = 26.0`
- Swift 6.0。`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` なので、指定しない型は MainActor に乗る。
  MainActor の外で動かしたい型には `nonisolated` を明示する
- App Sandbox 有効のまま。外部ライブラリと SPM 依存は追加しない
- テストは Swift Testing（`import Testing` / `@Suite` / `@Test` / `#expect`）。テスト名は日本語
- `AgentPets/` と `AgentPetsTests/` は `PBXFileSystemSynchronizedRootGroup` なので、`.swift` は
  置くだけでビルド対象に入る。pbxproj の編集は不要
- **`.json` と `.md` を `AgentPets/` や `AgentPetsTests/` に置いてはいけない。**
  `Contents/Resources/` に自動でコピーされ、製品バンドルに載る。テストのフィクスチャは
  コード内で生成して一時ディレクトリに書く
- 実ホーム配下（`~/.codex` を含む）を参照する API を呼ばない。`getpwuid` も使わない
- コミットメッセージは英語。命令形の件名、空行、本文は「なぜ」を書く。末尾に
  `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>` を付ける
  （既存 5 コミットの体裁に合わせる）
- 全テスト実行: `xcodebuild test -project AgentPets.xcodeproj -scheme AgentPets -destination 'platform=macOS'`
- 単一スイート実行: 上のコマンドに `-only-testing:AgentPetsTests/<SuiteType>` を足す
- 着手前のベースラインは 13 テスト全成功

## File Structure

| ファイル | 責務 | タスク |
| --- | --- | --- |
| `AgentPets/AgentPets.entitlements` | `bookmarks.app-scope` のみ | 1 |
| `AgentPets/PetManifest.swift` | `pet.json` のデコードと `spritesheetPath` の解決 | 2 |
| `AgentPets/SpriteSheet.swift` | アトラスのデコードとフレームの切り出し | 3 |
| `AgentPets/AnimationClip.swift` | 解決済みクリップ、既定スケジュール表、純粋関数 | 4 |
| `AgentPets/PetLibrary.swift` | フォルダの bookmark、ペットの列挙、選択の保持 | 5 |
| `AgentPets/PetAnimator.swift` | クリップの再生 | 6 |
| `AgentPets/SpeechBubble.swift` | 吹き出し | 7 |
| `AgentPets/PetSpriteView.swift` | スプライトの描画とクリップの切替 | 7 |
| `AgentPets/ContentView.swift` | スプライトと絵文字の切替（変更） | 7 |
| `AgentPets/AgentPetsApp.swift` | メニュー（変更） | 8 |
| `AgentPets/PetViewModel.swift` | イベント連番と RunLoop モード（変更） | 9 |
| `AgentPets/FloatingWindowController.swift` | リサイズと復元（変更） | 11 |
| `README.md` | 状態表、フォルダの選び方、セキュリティ節（変更） | 12 |

`PetState.swift` と `StatusPayload.swift` と `StatusNotificationListener.swift` と
`scripts/agentpets-notify.sh` は変更しない。

---

### Task 1: entitlements ファイルを追加する

security-scoped bookmark をアプリの再起動をまたいで使うには
`com.apple.security.files.bookmarks.app-scope` が要る。Xcode 27 のビルド設定にこれに対応する
項目が無いので、`.entitlements` ファイルを新設する。

`app-sandbox` と `user-selected.read-only` はビルド設定側に残す。両方に書くと同じ設定の
出どころが 2 か所になる。ビルド設定由来の entitlement とファイルの内容はマージされるので、
ファイルには 1 つだけ書けばよい。

**Files:**
- Create: `AgentPets/AgentPets.entitlements`
- Modify: `AgentPets.xcodeproj/project.pbxproj`（アプリターゲットの Debug と Release の 2 か所に
  `CODE_SIGN_ENTITLEMENTS` を追加）

**Interfaces:**
- Consumes: なし
- Produces: 署名済みアプリに `com.apple.security.files.bookmarks.app-scope` が入る

- [ ] **Step 1: 現状の entitlement を記録する**

```bash
xcodebuild build -project AgentPets.xcodeproj -scheme AgentPets \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath build >/dev/null 2>&1
codesign -d --entitlements :- build/Build/Products/Debug/AgentPets.app 2>/dev/null
```

`app-sandbox` / `files.user-selected.read-only` / `get-task-allow` の 3 つが出る。
`bookmarks.app-scope` は無い。

- [ ] **Step 2: entitlements ファイルを作る**

`AgentPets/AgentPets.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.files.bookmarks.app-scope</key>
	<true/>
</dict>
</plist>
```

- [ ] **Step 3: ビルド設定から参照する**

`AgentPets.xcodeproj/project.pbxproj` を開き、アプリターゲット（`PRODUCT_NAME = "$(TARGET_NAME)"`
かつ `ENABLE_APP_SANDBOX = YES` を持つ 2 つの `XCBuildConfiguration`）の `buildSettings` に
次の行を足す。`CODE_SIGN_STYLE = Automatic;` の直前がアルファベット順で収まる。

```
				CODE_SIGN_ENTITLEMENTS = AgentPets/AgentPets.entitlements;
```

テストターゲット側（`ENABLE_APP_SANDBOX` を持たない 2 つ）には足さない。

- [ ] **Step 4: 署名結果を確認する**

```bash
xcodebuild build -project AgentPets.xcodeproj -scheme AgentPets \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath build 2>&1 | tail -3
codesign -d --entitlements :- build/Build/Products/Debug/AgentPets.app 2>/dev/null
```

期待: `** BUILD SUCCEEDED **` と、`app-sandbox` / `bookmarks.app-scope` /
`files.user-selected.read-only` / `get-task-allow` の 4 つ。3 つに減っていたら
`CODE_SIGN_ENTITLEMENTS` の書き足し先を間違えている。

- [ ] **Step 5: 既存テストが壊れていないことを確認する**

```bash
xcodebuild test -project AgentPets.xcodeproj -scheme AgentPets -destination 'platform=macOS' 2>&1 | tail -3
```

期待: `** TEST SUCCEEDED **`

- [ ] **Step 6: コミット**

```bash
git add AgentPets/AgentPets.entitlements AgentPets.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
Add an entitlements file for app-scoped bookmarks

Reading a user-chosen pet folder across launches needs
com.apple.security.files.bookmarks.app-scope, and Xcode 27 has no build
setting for it — the sandbox settings it does expose cover the app
sandbox, the standard folders, and network access only.

Keep app-sandbox and user-selected.read-only in the build settings. The
file and the build settings are merged at signing time, so listing them
in both places would only split where the truth lives.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: PetManifest — pet.json を読む

必須は 4 フィールド。`frame` と `animations` は任意だが、**あれば厳格に読む**。
これらは hatch-pet の公開契約には無く、Codex CLI の内部モデルから推定したものなので、
「無ければ既定値」を持ち込むとフィールド名を取り違えていても黙って動いてしまう。
必須項目を非オプショナルにしておけば、欠けていれば `JSONDecoder` が投げる。

**Files:**
- Create: `AgentPets/PetManifest.swift`
- Test: `AgentPetsTests/PetManifestTests.swift`

**Interfaces:**
- Consumes: なし
- Produces:
  - `PetManifest`（`id` / `displayName` / `description` / `spritesheetPath` / `frame` / `animations`）
  - `PetManifest.FrameSpec`（`width` / `height` / `columns`、すべて `Int`）
  - `PetManifest.AnimationSpec`（`frames: [Int]` / `fps: Double?`）
  - `PetManifest.decode(_ data: Data) throws -> PetManifest`
  - `PetManifest.spritesheetURL(in packageURL: URL) -> URL?`

- [ ] **Step 1: 失敗するテストを書く**

`AgentPetsTests/PetManifestTests.swift`:

```swift
//
//  PetManifestTests.swift
//  AgentPetsTests
//

import Foundation
import Testing
@testable import AgentPets

@Suite("PetManifest")
struct PetManifestTests {

    private func json(_ raw: String) -> Data { Data(raw.utf8) }

    private let minimal = """
    {
      "id": "zundamon",
      "displayName": "Zundamon",
      "description": "A compact animated pet.",
      "spritesheetPath": "spritesheet.webp"
    }
    """

    @Test("4フィールドの最小形を読む")
    func decodesMinimal() throws {
        let manifest = try PetManifest.decode(json(minimal))

        #expect(manifest.id == "zundamon")
        #expect(manifest.displayName == "Zundamon")
        #expect(manifest.spritesheetPath == "spritesheet.webp")
        #expect(manifest.frame == nil)
        #expect(manifest.animations == nil)
    }

    @Test("frameとanimationsを持つ拡張形を読む")
    func decodesExtended() throws {
        let manifest = try PetManifest.decode(json("""
        {
          "id": "p", "displayName": "P", "description": "d",
          "spritesheetPath": "s.webp",
          "frame": { "width": 192, "height": 208, "columns": 8 },
          "animations": { "idle": { "frames": [0, 1, 2], "fps": 6 } }
        }
        """))

        #expect(manifest.frame == PetManifest.FrameSpec(width: 192, height: 208, columns: 8))
        #expect(manifest.animations?["idle"]?.frames == [0, 1, 2])
        #expect(manifest.animations?["idle"]?.fps == 6)
    }

    @Test("animationsにframesが無ければ既定値に落とさず失敗する")
    func rejectsAnimationWithoutFrames() {
        #expect(throws: (any Error).self) {
            try PetManifest.decode(json("""
            {
              "id": "p", "displayName": "P", "description": "d",
              "spritesheetPath": "s.webp",
              "animations": { "idle": { "fps": 6 } }
            }
            """))
        }
    }

    @Test("frameにcolumnsが無ければ失敗する")
    func rejectsFrameWithoutColumns() {
        #expect(throws: (any Error).self) {
            try PetManifest.decode(json("""
            {
              "id": "p", "displayName": "P", "description": "d",
              "spritesheetPath": "s.webp",
              "frame": { "width": 192, "height": 208 }
            }
            """))
        }
    }

    @Test("知らないキーは無視する")
    func ignoresUnknownKeys() throws {
        let manifest = try PetManifest.decode(json("""
        {
          "id": "p", "displayName": "P", "description": "d",
          "spritesheetPath": "s.webp",
          "schemaVersion": 7,
          "frame": { "width": 192, "height": 208, "columns": 8, "rows": 9 }
        }
        """))

        #expect(manifest.id == "p")
        #expect(manifest.frame?.columns == 8)
    }

    @Test("必須フィールドが欠けていれば失敗する")
    func rejectsMissingRequiredField() {
        #expect(throws: (any Error).self) {
            try PetManifest.decode(json("""
            { "id": "p", "displayName": "P", "description": "d" }
            """))
        }
    }

    @Test("壊れたJSONは失敗する")
    func rejectsMalformedJSON() {
        #expect(throws: (any Error).self) {
            try PetManifest.decode(json("{ not json"))
        }
    }

    @Test("spritesheetPathをパッケージ内で解決する")
    func resolvesSpritesheetURL() throws {
        let manifest = try PetManifest.decode(json(minimal))
        let package = URL(fileURLWithPath: "/tmp/pets/zundamon", isDirectory: true)

        #expect(manifest.spritesheetURL(in: package)?.path == "/tmp/pets/zundamon/spritesheet.webp")
    }

    @Test("パッケージ外を指すspritesheetPathを拒否する")
    func rejectsEscapingSpritesheetPath() throws {
        let package = URL(fileURLWithPath: "/tmp/pets/zundamon", isDirectory: true)

        for path in ["../other/sheet.webp", "/etc/passwd", "../../sheet.webp"] {
            let manifest = try PetManifest.decode(json("""
            {
              "id": "p", "displayName": "P", "description": "d",
              "spritesheetPath": "\(path)"
            }
            """))

            #expect(manifest.spritesheetURL(in: package) == nil, "\(path) を拒否していない")
        }
    }
}
```

- [ ] **Step 2: 失敗することを確認する**

```bash
xcodebuild test -project AgentPets.xcodeproj -scheme AgentPets \
  -destination 'platform=macOS' -only-testing:AgentPetsTests/PetManifestTests 2>&1 | tail -20
```

期待: `cannot find 'PetManifest' in scope` でコンパイルエラー。

- [ ] **Step 3: 実装する**

`AgentPets/PetManifest.swift`:

```swift
//
//  PetManifest.swift
//  AgentPets
//

import Foundation

/// ペットパッケージの `pet.json`。
///
/// 必須は hatch-pet の公開契約にある 4 つ。`frame` と `animations` は Codex CLI の内部モデルから
/// 推定した任意フィールドで、無ければ固定契約（8×9 / 192×208）が使われる。
///
/// 推定であることを踏まえて、書いてある場合は必須項目を欠かさないことを要求する。
/// `frames` や `columns` を省いても既定値で動いてしまうと、フィールド名の取り違えが表に出ない。
/// 非オプショナルにしてあるので、欠けていれば復号がそのまま失敗する。
nonisolated struct PetManifest: Decodable, Equatable {
    let id: String
    let displayName: String
    let description: String
    let spritesheetPath: String
    let frame: FrameSpec?
    let animations: [String: AnimationSpec]?

    nonisolated struct FrameSpec: Decodable, Equatable {
        let width: Int
        let height: Int
        let columns: Int
    }

    nonisolated struct AnimationSpec: Decodable, Equatable {
        let frames: [Int]
        let fps: Double?
    }

    static func decode(_ data: Data) throws -> PetManifest {
        try JSONDecoder().decode(PetManifest.self, from: data)
    }

    /// `spritesheetPath` をパッケージ内で解決する。パッケージの外を指すものは受け付けない。
    /// 絶対パスは `relativeTo:` を無視して自身が採用されるので、同じ前方一致で弾ける。
    func spritesheetURL(in packageURL: URL) -> URL? {
        let base = packageURL.standardizedFileURL
        let resolved = URL(fileURLWithPath: spritesheetPath, relativeTo: base).standardizedFileURL

        guard resolved.path.hasPrefix(base.path + "/") else { return nil }
        return resolved
    }
}
```

- [ ] **Step 4: 通ることを確認する**

```bash
xcodebuild test -project AgentPets.xcodeproj -scheme AgentPets \
  -destination 'platform=macOS' -only-testing:AgentPetsTests/PetManifestTests 2>&1 | tail -15
```

期待: 9 テストすべて passed。

- [ ] **Step 5: コミット**

```bash
git add AgentPets/PetManifest.swift AgentPetsTests/PetManifestTests.swift
git commit -m "$(cat <<'EOF'
Read pet.json into a manifest

The four fields in hatch-pet's published contract are required. frame
and animations are optional: they come from the Codex CLI's internal
model rather than the contract, and none of the packages that exist
today carry them.

Because those two are inferred, they are read strictly. Making frames,
width, height, and columns non-optional means a manifest that omits
them fails to decode instead of silently falling back to the fixed 8x9
grid — a fallback would hide the case where the guessed field names are
wrong.

spritesheetPath is resolved against the package and anything pointing
outside it is refused, absolute paths included.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: SpriteSheet — アトラスをフレームに切る

ImageIO で 1 回だけデコードし、フレームは `cropping(to:)` で取り出す。寸法が合わないアトラスは
読み込み失敗にする。`nonisolated` にして MainActor の外で動かす。

**Files:**
- Create: `AgentPets/SpriteSheet.swift`
- Test: `AgentPetsTests/SpriteSheetTests.swift`

**Interfaces:**
- Consumes: `PetManifest.FrameSpec`（Task 2）
- Produces:
  - `SpriteSheet`（`cellWidth` / `cellHeight` / `columns` / `rows` / `frameCount`）
  - `SpriteSheet.defaultFrame: PetManifest.FrameSpec`（192 / 208 / 8）
  - `SpriteSheet.load(contentsOf: URL, frame: PetManifest.FrameSpec?) throws -> SpriteSheet`
  - `SpriteSheet.frame(at: Int) -> CGImage?`
  - `SpriteSheet.rect(forIndex: Int, cellWidth: Int, cellHeight: Int, columns: Int) -> CGRect`
  - `SpriteSheetError`（`.decodeFailed` / `.invalidFrameSpec` / `.widthMismatch` / `.heightNotDivisible`）

- [ ] **Step 1: 失敗するテストを書く**

`AgentPetsTests/SpriteSheetTests.swift`:

```swift
//
//  SpriteSheetTests.swift
//  AgentPetsTests
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AgentPets

@Suite("SpriteSheet")
struct SpriteSheetTests {

    /// 実素材に依存しないよう、テスト内で不透明なアトラスPNGを作る。
    /// `.json` や `.md` と違い、一時ディレクトリに書けば製品バンドルには入らない。
    private func makeAtlas(width: Int, height: Int) throws -> URL {
        let context = try #require(CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.8, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("atlas-\(UUID().uuidString).png")
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test("既定の8×9アトラスを読む")
    func loadsDefaultAtlas() throws {
        let url = try makeAtlas(width: 1536, height: 1872)

        let sheet = try SpriteSheet.load(contentsOf: url, frame: nil)

        #expect(sheet.cellWidth == 192)
        #expect(sheet.cellHeight == 208)
        #expect(sheet.columns == 8)
        #expect(sheet.rows == 9)
        #expect(sheet.frameCount == 72)
    }

    @Test("幅がcolumns×widthと合わなければ失敗する")
    func rejectsWidthMismatch() throws {
        let url = try makeAtlas(width: 1500, height: 1872)

        #expect(throws: SpriteSheetError.widthMismatch) {
            try SpriteSheet.load(contentsOf: url, frame: nil)
        }
    }

    @Test("高さがセル高で割り切れなければ失敗する")
    func rejectsIndivisibleHeight() throws {
        let url = try makeAtlas(width: 1536, height: 1800)

        #expect(throws: SpriteSheetError.heightNotDivisible) {
            try SpriteSheet.load(contentsOf: url, frame: nil)
        }
    }

    @Test("manifestのframeがあればそちらを使う")
    func honorsManifestFrame() throws {
        let url = try makeAtlas(width: 120, height: 80)

        let sheet = try SpriteSheet.load(
            contentsOf: url,
            frame: PetManifest.FrameSpec(width: 40, height: 20, columns: 3)
        )

        #expect(sheet.rows == 4)
        #expect(sheet.frameCount == 12)
    }

    @Test("画像として読めないファイルは失敗する")
    func rejectsNonImage() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("not-an-image-\(UUID().uuidString).webp")
        try Data("hello".utf8).write(to: url)

        #expect(throws: SpriteSheetError.decodeFailed) {
            try SpriteSheet.load(contentsOf: url, frame: nil)
        }
    }

    @Test("フレーム番号を矩形に変換する")
    func convertsIndexToRect() {
        let rect = { SpriteSheet.rect(forIndex: $0, cellWidth: 192, cellHeight: 208, columns: 8) }

        #expect(rect(0) == CGRect(x: 0, y: 0, width: 192, height: 208))
        #expect(rect(7) == CGRect(x: 1344, y: 0, width: 192, height: 208))
        #expect(rect(8) == CGRect(x: 0, y: 208, width: 192, height: 208))
        #expect(rect(9) == CGRect(x: 192, y: 208, width: 192, height: 208))
    }

    @Test("範囲外のフレーム番号はnilを返す")
    func returnsNilForOutOfRangeIndex() throws {
        let sheet = try SpriteSheet.load(contentsOf: makeAtlas(width: 1536, height: 1872), frame: nil)

        #expect(sheet.frame(at: 0) != nil)
        #expect(sheet.frame(at: 71) != nil)
        #expect(sheet.frame(at: 72) == nil)
        #expect(sheet.frame(at: -1) == nil)
    }

    @Test("切り出したフレームはセルの大きさになる")
    func cropsToCellSize() throws {
        let sheet = try SpriteSheet.load(contentsOf: makeAtlas(width: 1536, height: 1872), frame: nil)

        let frame = try #require(sheet.frame(at: 42))

        #expect(frame.width == 192)
        #expect(frame.height == 208)
    }
}
```

- [ ] **Step 2: 失敗することを確認する**

```bash
xcodebuild test -project AgentPets.xcodeproj -scheme AgentPets \
  -destination 'platform=macOS' -only-testing:AgentPetsTests/SpriteSheetTests 2>&1 | tail -20
```

期待: `cannot find 'SpriteSheet' in scope` でコンパイルエラー。

- [ ] **Step 3: 実装する**

`AgentPets/SpriteSheet.swift`:

```swift
//
//  SpriteSheet.swift
//  AgentPets
//

import CoreGraphics
import Foundation
import ImageIO

nonisolated enum SpriteSheetError: Error, Equatable {
    case decodeFailed
    case invalidFrameSpec
    case widthMismatch
    case heightNotDivisible
}

/// スプライトアトラスと、そこから切り出したフレーム。
///
/// モジュール既定の分離が MainActor なので、`nonisolated` を明示して UI スレッドの外で
/// デコードできるようにしてある。1536×1872 のデコードは数十 ms かかる。
nonisolated struct SpriteSheet {
    let cellWidth: Int
    let cellHeight: Int
    let columns: Int
    let rows: Int

    private let atlas: CGImage

    var frameCount: Int { columns * rows }

    /// hatch-pet の固定契約。`pet.json` に `frame` が無いときはこれを使う。
    static let defaultFrame = PetManifest.FrameSpec(width: 192, height: 208, columns: 8)

    static func load(contentsOf url: URL, frame: PetManifest.FrameSpec?) throws -> SpriteSheet {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let atlas = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw SpriteSheetError.decodeFailed
        }

        let spec = frame ?? defaultFrame
        guard spec.width > 0, spec.height > 0, spec.columns > 0 else {
            throw SpriteSheetError.invalidFrameSpec
        }
        guard atlas.width == spec.width * spec.columns else {
            throw SpriteSheetError.widthMismatch
        }
        guard atlas.height % spec.height == 0, atlas.height >= spec.height else {
            throw SpriteSheetError.heightNotDivisible
        }

        return SpriteSheet(
            cellWidth: spec.width,
            cellHeight: spec.height,
            columns: spec.columns,
            rows: atlas.height / spec.height,
            atlas: atlas
        )
    }

    /// フレーム番号は「行 × columns ＋ 列」の平面インデックス。
    static func rect(forIndex index: Int, cellWidth: Int, cellHeight: Int, columns: Int) -> CGRect {
        CGRect(
            x: (index % columns) * cellWidth,
            y: (index / columns) * cellHeight,
            width: cellWidth,
            height: cellHeight
        )
    }

    func frame(at index: Int) -> CGImage? {
        guard index >= 0, index < frameCount else { return nil }
        return atlas.cropping(to: Self.rect(
            forIndex: index, cellWidth: cellWidth, cellHeight: cellHeight, columns: columns
        ))
    }
}
```

- [ ] **Step 4: 通ることを確認する**

```bash
xcodebuild test -project AgentPets.xcodeproj -scheme AgentPets \
  -destination 'platform=macOS' -only-testing:AgentPetsTests/SpriteSheetTests 2>&1 | tail -15
```

期待: 8 テストすべて passed。

- [ ] **Step 5: コミット**

```bash
git add AgentPets/SpriteSheet.swift AgentPetsTests/SpriteSheetTests.swift
git commit -m "$(cat <<'EOF'
Cut an atlas into sprite frames

ImageIO reads WebP directly, so the sheet is decoded once and each cell
comes out of cropping(to:). The type is nonisolated because the module
defaults to MainActor and a 1536x1872 decode has no business running on
the UI thread.

An atlas whose width is not columns times the cell width, or whose
height does not divide by the cell height, is refused rather than
rendered as garbage. The row count is derived from the height instead
of read from the manifest: the field name for it could not be pinned
down in the Codex CLI, and deriving it needs no guess.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: AnimationClip — 状態からクリップを決める

状態・マニフェスト・固定契約の 3 つを 1 つの値型に畳む。フレーム番号と次の切り替え時刻を
求める関数は時計に依存しない純粋関数にして、テストが実時間を待たなくて済むようにする。

`PetState` には手を入れない。状態から行への対応表はこちらに置く。

**Files:**
- Create: `AgentPets/AnimationClip.swift`
- Test: `AgentPetsTests/AnimationClipTests.swift`

**Interfaces:**
- Consumes: `PetManifest`（Task 2）、`SpriteSheet`（Task 3）、`PetState`（既存）
- Produces:
  - `AnimationClip`（`frameIndices: [Int]` / `durations: [TimeInterval]` / `repeats: Bool`）
  - `PetAnimation.Row`（`index: Int` / `durations: [TimeInterval]`）
  - `PetAnimation.rows: [String: Row]`
  - `PetAnimation.stateAnimations: [PetState: StateAnimation]`
  - `PetAnimation.StateAnimation`（`name: String` / `repeats: Bool` / `then: PetState?`）
  - `PetAnimation.clip(for: PetState, manifest: PetManifest, sheet: SpriteSheet) -> AnimationClip?`
  - `PetAnimation.slot(elapsed: TimeInterval, durations: [TimeInterval], repeats: Bool) -> Int`
  - `PetAnimation.nextBoundary(after: TimeInterval, durations: [TimeInterval], repeats: Bool) -> TimeInterval?`

- [ ] **Step 1: 失敗するテストを書く**

`AgentPetsTests/AnimationClipTests.swift`:

```swift
//
//  AnimationClipTests.swift
//  AgentPetsTests
//

import Foundation
import Testing
@testable import AgentPets

@Suite("PetAnimation")
struct AnimationClipTests {

    private let durations: [TimeInterval] = [0.1, 0.2, 0.3]   // 合計 0.6

    @Test("ループは経過時間の剰余でフレームを選ぶ")
    func loopsByRemainder() {
        let slot = { PetAnimation.slot(elapsed: $0, durations: durations, repeats: true) }

        #expect(slot(0.00) == 0)
        #expect(slot(0.05) == 0)
        #expect(slot(0.10) == 1)
        #expect(slot(0.29) == 1)
        #expect(slot(0.30) == 2)
        #expect(slot(0.59) == 2)
        #expect(slot(0.60) == 0)   // 2周目の先頭
        #expect(slot(0.95) == 2)   // 2周目の 0.35 の位置
        #expect(slot(1.25) == 0)   // 3周目の 0.05 の位置
    }

    @Test("ループしない場合は最終フレームで止まる")
    func clampsAtLastFrame() {
        let slot = { PetAnimation.slot(elapsed: $0, durations: durations, repeats: false) }

        #expect(slot(0.00) == 0)
        #expect(slot(0.30) == 2)
        #expect(slot(0.60) == 2)
        #expect(slot(99.0) == 2)
    }

    @Test("負の経過時間と空の配列でも落ちない")
    func handlesDegenerateInput() {
        #expect(PetAnimation.slot(elapsed: -5, durations: durations, repeats: true) == 0)
        #expect(PetAnimation.slot(elapsed: 1, durations: [], repeats: true) == 0)
        #expect(PetAnimation.slot(elapsed: 1, durations: [0, 0], repeats: true) == 0)
    }

    @Test("次の切り替え時刻を絶対時刻で返す")
    func computesNextBoundary() throws {
        let next = { PetAnimation.nextBoundary(after: $0, durations: durations, repeats: true) }

        #expect(try #require(next(0.00)).isApproximately(0.1))
        #expect(try #require(next(0.05)).isApproximately(0.1))
        #expect(try #require(next(0.10)).isApproximately(0.3))
        #expect(try #require(next(0.35)).isApproximately(0.6))
        #expect(try #require(next(0.60)).isApproximately(0.7))   // 2周目
    }

    @Test("ループしない場合は最後まで来たら次の切り替えが無い")
    func stopsBoundaryAtEnd() throws {
        let next = { PetAnimation.nextBoundary(after: $0, durations: durations, repeats: false) }

        #expect(try #require(next(0.35)).isApproximately(0.6))
        #expect(next(0.60) == nil)
        #expect(next(5.00) == nil)
    }

    @Test("5つの状態すべてにアトラス上の行が対応する")
    func mapsEveryState() {
        let states: Set<PetState> = [.idle, .working, .waiting, .success, .error]

        #expect(Set(PetAnimation.stateAnimations.keys) == states)

        for (state, animation) in PetAnimation.stateAnimations {
            let row = PetAnimation.rows[animation.name]
            #expect(row != nil, "\(state) の行 \(animation.name) が既定表に無い")
            #expect((row?.index ?? -1) < 9, "\(state) の行が9行に収まっていない")
        }
    }

    @Test("既定スケジュールのフレーム数と合計時間が仕様と一致する")
    func matchesPublishedSchedule() throws {
        // animation-rows.md の Used columns と表示時間
        let expected: [String: (frames: Int, total: TimeInterval)] = [
            "idle":          (6, 1.100),
            "running-right": (8, 1.060),
            "running-left":  (8, 1.060),
            "waving":        (4, 0.700),
            "jumping":       (5, 0.840),
            "failed":        (8, 1.220),
            "waiting":       (6, 1.010),
            "running":       (6, 0.820),
            "review":        (6, 1.030),
        ]

        #expect(Set(PetAnimation.rows.keys) == Set(expected.keys))

        for (name, want) in expected {
            let row = try #require(PetAnimation.rows[name])
            #expect(row.durations.count == want.frames, "\(name) のフレーム数")
            #expect(row.durations.reduce(0, +).isApproximately(want.total), "\(name) の合計時間")
        }
    }

    @Test("行の並びが仕様どおり")
    func matchesRowOrder() throws {
        let order = ["idle", "running-right", "running-left", "waving",
                     "jumping", "failed", "waiting", "running", "review"]

        for (index, name) in order.enumerated() {
            #expect(try #require(PetAnimation.rows[name]).index == index, name)
        }
    }
}

private extension TimeInterval {
    func isApproximately(_ other: TimeInterval) -> Bool { abs(self - other) < 0.0005 }
}
```

- [ ] **Step 2: 失敗することを確認する**

```bash
xcodebuild test -project AgentPets.xcodeproj -scheme AgentPets \
  -destination 'platform=macOS' -only-testing:AgentPetsTests/AnimationClipTests 2>&1 | tail -20
```

期待: `cannot find 'PetAnimation' in scope` でコンパイルエラー。

- [ ] **Step 3: 実装する**

`AgentPets/AnimationClip.swift`:

```swift
//
//  AnimationClip.swift
//  AgentPets
//

import Foundation

/// 再生する準備が整ったアニメーション。
/// 状態・マニフェスト・固定契約はここに畳まれるので、再生側はこの型しか知らない。
nonisolated struct AnimationClip: Equatable {
    let frameIndices: [Int]
    let durations: [TimeInterval]
    /// false なら最終フレームで止まる。
    let repeats: Bool
}

nonisolated enum PetAnimation {

    nonisolated struct Row: Equatable {
        let index: Int
        let durations: [TimeInterval]
    }

    nonisolated struct StateAnimation: Equatable {
        let name: String
        let repeats: Bool
        /// 1 周したあとに移る状態。nil ならその場に留まる。
        let then: PetState?
    }

    private static func ms(_ values: Int...) -> [TimeInterval] {
        values.map { TimeInterval($0) / 1000 }
    }

    /// hatch-pet の animation-rows.md にある固定契約。
    static let rows: [String: Row] = [
        "idle":          Row(index: 0, durations: ms(280, 110, 110, 140, 140, 320)),
        "running-right": Row(index: 1, durations: ms(120, 120, 120, 120, 120, 120, 120, 220)),
        "running-left":  Row(index: 2, durations: ms(120, 120, 120, 120, 120, 120, 120, 220)),
        "waving":        Row(index: 3, durations: ms(140, 140, 140, 280)),
        "jumping":       Row(index: 4, durations: ms(140, 140, 140, 140, 280)),
        "failed":        Row(index: 5, durations: ms(140, 140, 140, 140, 140, 140, 140, 240)),
        "waiting":       Row(index: 6, durations: ms(150, 150, 150, 150, 150, 260)),
        "running":       Row(index: 7, durations: ms(120, 120, 120, 120, 120, 220)),
        "review":        Row(index: 8, durations: ms(150, 150, 150, 150, 150, 280)),
    ]

    /// 状態と行の対応。`PetState` は通信仕様の型なので、表示の都合はこちらに置く。
    ///
    /// success は跳ねてから待機に戻る。error は落ち込んだまま留まる。失敗が視界から消えると
    /// 状態表示として機能しないため。
    static let stateAnimations: [PetState: StateAnimation] = [
        .idle:    StateAnimation(name: "idle",    repeats: true,  then: nil),
        .working: StateAnimation(name: "running", repeats: true,  then: nil),
        .waiting: StateAnimation(name: "waiting", repeats: true,  then: nil),
        .success: StateAnimation(name: "jumping", repeats: false, then: .idle),
        .error:   StateAnimation(name: "failed",  repeats: false, then: nil),
    ]

    /// `animations` に fps しか無いときに使う、1 フレームあたりの時間。
    static let fallbackFrameDuration: TimeInterval = 0.15

    static func clip(for state: PetState, manifest: PetManifest, sheet: SpriteSheet) -> AnimationClip? {
        guard let animation = stateAnimations[state] else { return nil }

        if let spec = manifest.animations?[animation.name] {
            guard !spec.frames.isEmpty,
                  spec.frames.allSatisfy({ $0 >= 0 && $0 < sheet.frameCount }) else { return nil }

            let durations: [TimeInterval]
            if let fps = spec.fps, fps > 0, fps.isFinite {
                durations = Array(repeating: 1 / fps, count: spec.frames.count)
            } else if let row = rows[animation.name], row.durations.count == spec.frames.count {
                durations = row.durations
            } else {
                durations = Array(repeating: fallbackFrameDuration, count: spec.frames.count)
            }

            return AnimationClip(
                frameIndices: spec.frames, durations: durations, repeats: animation.repeats
            )
        }

        guard let row = rows[animation.name], row.index < sheet.rows else { return nil }
        let indices = (0..<row.durations.count).map { row.index * sheet.columns + $0 }
        guard indices.allSatisfy({ $0 < sheet.frameCount }) else { return nil }

        return AnimationClip(
            frameIndices: indices, durations: row.durations, repeats: animation.repeats
        )
    }

    /// 経過時間から表示すべきフレームの位置を返す。時計に触らないのでテストしやすい。
    ///
    /// 境界の比較には許容誤差が要る。`0.1 + 0.2` は `0.30000000000000004` になり、
    /// `[0.1, 0.2, 0.3]` の合計は `0.6000000000000001` になるので、厳密比較だと
    /// 境界ちょうどの時刻が 1 つ手前のフレームに落ちる（`slot(0.30)` が 2 でなく 1、
    /// `slot(0.60)` が 0 でなく 2 になる）。ミリ秒単位の表より十分細かい誤差を許すこと。
    static func slot(elapsed: TimeInterval, durations: [TimeInterval], repeats: Bool) -> Int {
        guard !durations.isEmpty else { return 0 }
        let total = durations.reduce(0, +)
        guard total > 0 else { return 0 }

        var position = max(0, elapsed)
        if repeats {
            position = position.truncatingRemainder(dividingBy: total)
        } else if position >= total {
            return durations.count - 1
        }

        var accumulated: TimeInterval = 0
        for (index, duration) in durations.enumerated() {
            accumulated += duration
            if position < accumulated { return index }
        }
        return durations.count - 1
    }

    /// 次にフレームが切り替わる時刻を、再生開始からの経過時間で返す。
    /// 「今から何秒後」ではなく絶対時刻で持つことで、タイマーの誤差が累積しない。
    static func nextBoundary(
        after elapsed: TimeInterval, durations: [TimeInterval], repeats: Bool
    ) -> TimeInterval? {
        guard !durations.isEmpty else { return nil }
        let total = durations.reduce(0, +)
        guard total > 0 else { return nil }

        let position = max(0, elapsed)
        if !repeats && position >= total { return nil }

        let completedCycles = repeats ? (position / total).rounded(.down) : 0
        var accumulated: TimeInterval = 0
        for duration in durations {
            accumulated += duration
            let boundary = completedCycles * total + accumulated
            if boundary > position { return boundary }
        }
        return repeats ? (completedCycles + 1) * total : nil
    }
}
```

- [ ] **Step 4: 通ることを確認する**

```bash
xcodebuild test -project AgentPets.xcodeproj -scheme AgentPets \
  -destination 'platform=macOS' -only-testing:AgentPetsTests/AnimationClipTests 2>&1 | tail -15
```

期待: 8 テストすべて passed。落ちる場合はまず `rows` の表と `animation-rows.md` を突き合わせる。

- [ ] **Step 5: コミット**

```bash
git add AgentPets/AnimationClip.swift AgentPetsTests/AnimationClipTests.swift
git commit -m "$(cat <<'EOF'
Resolve a pet state into a playable clip

State, manifest, and the fixed contract collapse into one value before
anything plays it, so the player depends on neither PetState nor
PetManifest. The state-to-row table lives here rather than on PetState,
which is the notification contract's enum and should not grow display
concerns.

Frame selection is a pure function of elapsed time: a remainder when the
clip loops, a clamp when it does not. Keeping the clock out of it means
the tests run instantly instead of waiting out a 1.2 second cycle, and
it collapses what would otherwise be two playback paths into one flag.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: PetLibrary — フォルダとペットの管理

登録できるフォルダは 1 つ。bookmark は `UserDefaults` に持つ。走査は直下 1 階層だけで、
`pet.json` を持つディレクトリをペットとみなす。

ファイルシステムを歩く部分（`PetDiscovery`）を `nonisolated` の静的関数として切り出し、
テストは一時ディレクトリに対して行う。bookmark の生成と解決は差し替えられる形にしておく。
`NSOpenPanel` が付与する本番の経路はテストで再現できないので、そこは手動確認とする。

**Files:**
- Create: `AgentPets/PetLibrary.swift`
- Test: `AgentPetsTests/PetLibraryTests.swift`

**Interfaces:**
- Consumes: `PetManifest`（Task 2）、`SpriteSheet`（Task 3）
- Produces:
  - `Pet`（`id: String` / `displayName: String` / `packageURL: URL` / `manifest: PetManifest`）
  - `PetDiscovery.pets(in folder: URL) -> [Pet]`
  - `BookmarkResolving`（`data(for:) throws -> Data` / `url(from:) throws -> (URL, Bool)`）
  - `PetLibrary`（`@MainActor @Observable`。`pets` / `selection` / `sheet` / `folderURL`）
  - `PetLibrary.setFolder(_ url: URL)` / `select(_ pet: Pet?)` / `restore()`

- [ ] **Step 1: 失敗するテストを書く**

`AgentPetsTests/PetLibraryTests.swift`:

```swift
//
//  PetLibraryTests.swift
//  AgentPetsTests
//

import Foundation
import Testing
@testable import AgentPets

@Suite("PetDiscovery")
struct PetDiscoveryTests {

    private func makeFolder() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makePackage(in folder: URL, id: String) throws {
        let package = folder.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("""
        {
          "id": "\(id)", "displayName": "\(id.capitalized)",
          "description": "d", "spritesheetPath": "spritesheet.webp"
        }
        """.utf8).write(to: package.appendingPathComponent("pet.json"))
    }

    @Test("pet.jsonを持つディレクトリを拾う")
    func findsPackages() throws {
        let folder = try makeFolder()
        try makePackage(in: folder, id: "zundamon")
        try makePackage(in: folder, id: "moka")

        let pets = PetDiscovery.pets(in: folder)

        #expect(pets.map(\.id).sorted() == ["moka", "zundamon"])
        #expect(pets.map(\.packageURL.lastPathComponent).sorted() == ["moka", "zundamon"])
    }

    @Test("pet.jsonを持たないディレクトリは拾わない")
    func skipsDirectoriesWithoutManifest() throws {
        let folder = try makeFolder()
        try makePackage(in: folder, id: "zundamon")
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("empty", isDirectory: true),
            withIntermediateDirectories: true
        )

        #expect(PetDiscovery.pets(in: folder).map(\.id) == ["zundamon"])
    }

    @Test("直下のファイルは拾わない")
    func skipsPlainFiles() throws {
        let folder = try makeFolder()
        try makePackage(in: folder, id: "zundamon")
        try Data("x".utf8).write(to: folder.appendingPathComponent("README.txt"))
        try Data("{}".utf8).write(to: folder.appendingPathComponent("pet.json"))

        #expect(PetDiscovery.pets(in: folder).map(\.id) == ["zundamon"])
    }

    @Test("2階層目は拾わない")
    func doesNotRecurse() throws {
        let folder = try makeFolder()
        let nested = folder.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try makePackage(in: nested, id: "deep")

        #expect(PetDiscovery.pets(in: folder).isEmpty)
    }

    @Test("壊れたpet.jsonのディレクトリは飛ばして続ける")
    func skipsBrokenManifest() throws {
        let folder = try makeFolder()
        try makePackage(in: folder, id: "zundamon")
        let broken = folder.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: broken.appendingPathComponent("pet.json"))

        #expect(PetDiscovery.pets(in: folder).map(\.id) == ["zundamon"])
    }

    @Test("存在しないフォルダでは空を返す")
    func returnsEmptyForMissingFolder() {
        let missing = URL(fileURLWithPath: "/tmp/definitely-not-here-\(UUID().uuidString)")

        #expect(PetDiscovery.pets(in: missing).isEmpty)
    }

    @Test("表示名の順に並べる")
    func sortsByDisplayName() throws {
        let folder = try makeFolder()
        for id in ["zundamon", "aria", "moka"] { try makePackage(in: folder, id: id) }

        #expect(PetDiscovery.pets(in: folder).map(\.id) == ["aria", "moka", "zundamon"])
    }
}

@Suite("PetLibrary")
@MainActor
struct PetLibraryTests {

    /// 本番の bookmark は NSOpenPanel が付与した URL にしか作れないので、
    /// 保存と解決の経路だけを差し替えて確かめる。
    private final class FakeBookmarks: BookmarkResolving {
        var stored: [Data: URL] = [:]
        var isStale = false
        private var generation = 0

        // 世代番号を混ぜるのは、作り直された bookmark を値で見分けるため。
        // パスから決定的に作ると、保存し直されたかどうかがテストから区別できない。
        func data(for url: URL) throws -> Data {
            generation += 1
            let data = Data("\(url.path)#\(generation)".utf8)
            stored[data] = url
            return data
        }

        // タプルのラベルは型の一部で、外すと適合しない。protocol と同じ形で書く。
        func url(from data: Data) throws -> (url: URL, isStale: Bool) {
            guard let url = stored[data] else { throw CocoaError(.fileNoSuchFile) }
            return (url, isStale)
        }
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "PetLibraryTests-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    @Test("フォルダを設定するとペットが並ぶ")
    func listsPetsAfterSettingFolder() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lib-\(UUID().uuidString)", isDirectory: true)
        let package = folder.appendingPathComponent("zundamon", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("""
        { "id": "zundamon", "displayName": "Zundamon",
          "description": "d", "spritesheetPath": "spritesheet.webp" }
        """.utf8).write(to: package.appendingPathComponent("pet.json"))

        let library = PetLibrary(defaults: makeDefaults(), bookmarks: FakeBookmarks())
        library.setFolder(folder)

        #expect(library.pets.map(\.id) == ["zundamon"])
        #expect(library.folderURL == folder)
    }

    @Test("選択したペットを覚えて復元する")
    func restoresSelection() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lib-\(UUID().uuidString)", isDirectory: true)
        for id in ["zundamon", "moka"] {
            let package = folder.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            try Data("""
            { "id": "\(id)", "displayName": "\(id)",
              "description": "d", "spritesheetPath": "spritesheet.webp" }
            """.utf8).write(to: package.appendingPathComponent("pet.json"))
        }

        let defaults = makeDefaults()
        let bookmarks = FakeBookmarks()

        let first = PetLibrary(defaults: defaults, bookmarks: bookmarks)
        first.setFolder(folder)
        first.select(first.pets.first { $0.id == "moka" })
        #expect(first.selection?.id == "moka")

        let second = PetLibrary(defaults: defaults, bookmarks: bookmarks)
        second.restore()

        #expect(second.folderURL == folder)
        #expect(second.selection?.id == "moka")
    }

    @Test("フォルダ未設定なら空のまま")
    func staysEmptyWithoutFolder() {
        let library = PetLibrary(defaults: makeDefaults(), bookmarks: FakeBookmarks())
        library.restore()

        #expect(library.folderURL == nil)
        #expect(library.pets.isEmpty)
        #expect(library.selection == nil)
    }

    @Test("staleなbookmarkを作り直して保存し直す")
    func refreshesStaleBookmark() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lib-\(UUID().uuidString)", isDirectory: true)
        let package = folder.appendingPathComponent("zundamon", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("""
        { "id": "zundamon", "displayName": "Zundamon",
          "description": "d", "spritesheetPath": "spritesheet.webp" }
        """.utf8).write(to: package.appendingPathComponent("pet.json"))

        let defaults = makeDefaults()
        let bookmarks = FakeBookmarks()

        let first = PetLibrary(defaults: defaults, bookmarks: bookmarks)
        first.setFolder(folder)
        let original = try #require(defaults.data(forKey: "petFolderBookmark"))

        bookmarks.isStale = true
        let second = PetLibrary(defaults: defaults, bookmarks: bookmarks)
        second.restore()

        let refreshed = try #require(defaults.data(forKey: "petFolderBookmark"))
        #expect(refreshed != original, "staleなbookmarkが作り直されていない")
        #expect(second.folderURL == folder)
        #expect(second.isFolderMissing == false)
        #expect(second.pets.isEmpty == false)
    }

    @Test("解決できない bookmark は見つからない扱いにする")
    func reportsMissingFolder() throws {
        let defaults = makeDefaults()
        let bookmarks = FakeBookmarks()
        let folder = URL(fileURLWithPath: "/tmp/gone-\(UUID().uuidString)", isDirectory: true)

        let first = PetLibrary(defaults: defaults, bookmarks: bookmarks)
        first.setFolder(folder)

        bookmarks.stored.removeAll()
        let second = PetLibrary(defaults: defaults, bookmarks: bookmarks)
        second.restore()

        #expect(second.folderURL == nil)
        #expect(second.isFolderMissing)
    }
}
```

- [ ] **Step 2: 失敗することを確認する**

```bash
xcodebuild test -project AgentPets.xcodeproj -scheme AgentPets -destination 'platform=macOS' \
  -only-testing:AgentPetsTests/PetDiscoveryTests -only-testing:AgentPetsTests/PetLibraryTests 2>&1 | tail -20
```

期待: `cannot find 'PetDiscovery' in scope` でコンパイルエラー。

- [ ] **Step 3: 実装する**

`AgentPets/PetLibrary.swift`:

```swift
//
//  PetLibrary.swift
//  AgentPets
//

import Foundation
import Observation

nonisolated struct Pet: Identifiable, Equatable {
    let id: String
    let displayName: String
    let packageURL: URL
    let manifest: PetManifest
}

/// フォルダ直下からペットパッケージを拾う。
/// ファイルシステムを歩くだけなので `nonisolated` にしてテストから直接呼べるようにしてある。
nonisolated enum PetDiscovery {
    static let manifestName = "pet.json"

    static func pets(in folder: URL) -> [Pet] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return entries.compactMap { entry -> Pet? in
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let data = try? Data(contentsOf: entry.appendingPathComponent(manifestName)),
                  let manifest = try? PetManifest.decode(data) else { return nil }

            return Pet(
                id: manifest.id,
                displayName: manifest.displayName,
                packageURL: entry,
                manifest: manifest
            )
        }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
}

/// security-scoped bookmark の生成と解決。テストで差し替えられるように分けてある。
nonisolated protocol BookmarkResolving {
    func data(for url: URL) throws -> Data
    func url(from data: Data) throws -> (url: URL, isStale: Bool)
}

nonisolated struct SecurityScopedBookmarks: BookmarkResolving {
    func data(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    func url(from data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
    }
}

/// ユーザーが選んだ 1 つのフォルダと、そこにいるペット。
///
/// このアプリはここで設定されたフォルダ以外を見ない。既知の場所を推測して探しに行くことはしない。
@MainActor
@Observable
final class PetLibrary {
    private(set) var pets: [Pet] = []
    private(set) var selection: Pet?
    private(set) var folderURL: URL?
    private(set) var isFolderMissing = false

    private let defaults: UserDefaults
    private let bookmarks: any BookmarkResolving
    private var accessedURL: URL?

    private enum Key {
        static let bookmark = "petFolderBookmark"
        static let selection = "selectedPetID"
    }

    init(defaults: UserDefaults = .standard, bookmarks: any BookmarkResolving = SecurityScopedBookmarks()) {
        self.defaults = defaults
        self.bookmarks = bookmarks
    }

    /// 起動時に呼ぶ。保存済みの bookmark があれば解決してペットを並べ直す。
    func restore() {
        guard let data = defaults.data(forKey: Key.bookmark) else { return }

        guard let resolved = try? bookmarks.url(from: data) else {
            isFolderMissing = true
            return
        }

        if resolved.isStale, let fresh = try? bookmarks.data(for: resolved.url) {
            defaults.set(fresh, forKey: Key.bookmark)
        }

        adopt(resolved.url)
        if let id = defaults.string(forKey: Key.selection) {
            selection = pets.first { $0.id == id } ?? pets.first
        } else {
            selection = pets.first
        }
    }

    /// `NSOpenPanel` で選ばれたフォルダを登録する。
    func setFolder(_ url: URL) {
        if let data = try? bookmarks.data(for: url) {
            defaults.set(data, forKey: Key.bookmark)
        }
        adopt(url)
        select(pets.first)
    }

    func select(_ pet: Pet?) {
        selection = pet
        if let pet {
            defaults.set(pet.id, forKey: Key.selection)
        } else {
            defaults.removeObject(forKey: Key.selection)
        }
    }

    /// アクセス権は 1 フォルダにつき 1 回だけ取る。取り直す前に必ず前の分を返す。
    /// 返さずに積み上げるとカーネル資源を漏らし、いずれ Powerbox が使えなくなる。
    private func adopt(_ url: URL) {
        if let accessedURL {
            accessedURL.stopAccessingSecurityScopedResource()
            self.accessedURL = nil
        }
        if url.startAccessingSecurityScopedResource() {
            accessedURL = url
        }

        folderURL = url
        isFolderMissing = false
        pets = PetDiscovery.pets(in: url)
    }
}
```

- [ ] **Step 4: 通ることを確認する**

```bash
xcodebuild test -project AgentPets.xcodeproj -scheme AgentPets -destination 'platform=macOS' \
  -only-testing:AgentPetsTests/PetDiscoveryTests -only-testing:AgentPetsTests/PetLibraryTests 2>&1 | tail -15
```

期待: 11 テストすべて passed。

- [ ] **Step 5: コミット**

```bash
git add AgentPets/PetLibrary.swift AgentPetsTests/PetLibraryTests.swift
git commit -m "$(cat <<'EOF'
Track one user-chosen pet folder

The app looks at the folder the user picks and nowhere else. It does not
probe for well-known locations: a menu bar app quietly reading another
tool's config directory is hard to justify, and the sandbox would let it
check for one even though it could not read it.

Access is taken once per folder and released before taking another.
NSURL's documentation is explicit that failing to relinquish leaks
kernel resources until the app is relaunched, and a relaunch is exactly
what a resident app avoids.

Bookmark creation and resolution sit behind a protocol. The real path
runs on a URL that Powerbox handed to NSOpenPanel, which a test cannot
reproduce, so the tests cover storage and the stale branch and the
grant itself is checked by hand.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: PetAnimator — クリップを再生する

`Timer` は次のフレームまでの時間で張り直す。`RunLoop` の `.common` モードに入れないと、
メニューを開いている間とウィンドウのドラッグ中に止まる。クロージャは nonisolated なので
`MainActor.assumeIsolated` を通す。

**Files:**
- Create: `AgentPets/PetAnimator.swift`
- Test: `AgentPetsTests/PetAnimatorTests.swift`

**Interfaces:**
- Consumes: `AnimationClip` / `PetAnimation`（Task 4）
- Produces:
  - `PetAnimator`（`@MainActor @Observable`）
  - `PetAnimator.slot: Int`
  - `PetAnimator.isStill: Bool`（true なら先頭フレームで静止し、タイマーを張らない）
  - `PetAnimator.onFinished: (() -> Void)?`
  - `PetAnimator.play(_ clip: AnimationClip?)` / `stop()`

- [ ] **Step 1: 失敗するテストを書く**

`AgentPetsTests/PetAnimatorTests.swift`:

```swift
//
//  PetAnimatorTests.swift
//  AgentPetsTests
//

import Foundation
import Testing
@testable import AgentPets

@Suite("PetAnimator")
@MainActor
struct PetAnimatorTests {

    private let looping = AnimationClip(
        frameIndices: [0, 1, 2], durations: [0.05, 0.05, 0.05], repeats: true
    )
    private let once = AnimationClip(
        frameIndices: [10, 11], durations: [0.05, 0.05], repeats: false
    )
    /// 1 フレーム進んだあとは動かないクリップ。タイマーが遅れても `slot` が巻き戻らないので、
    /// 「進んだこと」を負荷に左右されずに確かめられる。
    ///
    /// ループするクリップでこれをやってはいけない。`looping` は合計 150ms なので、発火が
    /// 遅れて 150ms を跨ぐと `slot` が 0 に戻り、待ち時間を伸ばしても伸ばした先でまた戻る。
    private let advancesThenParks = AnimationClip(
        frameIndices: [20, 21], durations: [0.05, 10], repeats: false
    )

    // `play()` の直後に slot == 0 を見るだけでは、動いているリセットと no-op を区別できない
    // （初期値が 0 で、await が無いので run loop も回らない）。先に進めてから確かめる。
    // 同じクリップの再生し直しは、同じ状態が連投されたときに再生をやり直す仕組みの土台でもある。
    @Test("同じクリップを再生し直すと先頭に戻る")
    func restartsOnSameClip() async throws {
        let animator = PetAnimator()
        animator.play(advancesThenParks)
        try await Task.sleep(for: .milliseconds(150))
        #expect(animator.slot != 0, "先に進んでいないと、やり直しを確かめられない")

        animator.play(advancesThenParks)

        #expect(animator.slot == 0)
        #expect(animator.frameIndex == advancesThenParks.frameIndices.first)
    }

    @Test("クリップを差し替えると先頭に戻る")
    func restartsOnNewClip() async throws {
        let animator = PetAnimator()
        animator.play(advancesThenParks)
        try await Task.sleep(for: .milliseconds(150))
        #expect(animator.slot != 0)

        animator.play(once)

        #expect(animator.slot == 0)
    }

    @Test("動きを減らす設定では先頭フレームのまま進まない")
    func staysStillWhenReduced() async throws {
        let animator = PetAnimator()
        animator.isStill = true

        animator.play(looping)
        try await Task.sleep(for: .milliseconds(200))

        #expect(animator.slot == 0)
    }

    @Test("ループしないクリップは終わったら通知する")
    func reportsFinish() async throws {
        let animator = PetAnimator()
        var finished = 0
        animator.onFinished = { finished += 1 }

        animator.play(once)
        try await Task.sleep(for: .milliseconds(500))

        #expect(finished == 1)
        #expect(animator.slot == 1)
    }

    @Test("ループするクリップでは終了を通知しない")
    func doesNotReportFinishWhenLooping() async throws {
        let animator = PetAnimator()
        var finished = 0
        animator.onFinished = { finished += 1 }

        animator.play(looping)
        try await Task.sleep(for: .milliseconds(250))

        #expect(finished == 0)
    }

    @Test("nilを渡すと止まる")
    func stopsOnNilClip() {
        let animator = PetAnimator()
        animator.play(looping)

        animator.play(nil)

        #expect(animator.slot == 0)
        #expect(animator.frameIndex == nil)
    }

    @Test("現在のフレーム番号をクリップから引く")
    func exposesFrameIndex() {
        let animator = PetAnimator()

        animator.play(once)

        #expect(animator.frameIndex == 10)
    }
}
```

- [ ] **Step 2: 失敗することを確認する**

```bash
xcodebuild test -project AgentPets.xcodeproj -scheme AgentPets \
  -destination 'platform=macOS' -only-testing:AgentPetsTests/PetAnimatorTests 2>&1 | tail -20
```

期待: `cannot find 'PetAnimator' in scope` でコンパイルエラー。

- [ ] **Step 3: 実装する**

`AgentPets/PetAnimator.swift`:

```swift
//
//  PetAnimator.swift
//  AgentPets
//

import Foundation
import Observation
import QuartzCore

/// クリップを再生し、いま出すべきフレームを持つ。
///
/// フレームの決定は `PetAnimation` の純粋関数に任せ、こちらは時計とタイマーだけを見る。
@MainActor
@Observable
final class PetAnimator {
    private(set) var slot = 0

    /// 動きを減らす設定のときに立てる。先頭フレームで止め、タイマーを張らない。
    var isStill = false {
        didSet { if isStill != oldValue { restart() } }
    }

    /// ループしないクリップが最後まで来たときに 1 度だけ呼ばれる。
    var onFinished: (() -> Void)?

    private var clip: AnimationClip?
    private var startedAt: CFTimeInterval = 0
    private var timer: Timer?
    private var hasFinished = false

    var frameIndex: Int? {
        guard let clip, clip.frameIndices.indices.contains(slot) else { return nil }
        return clip.frameIndices[slot]
    }

    func play(_ clip: AnimationClip?) {
        self.clip = clip
        restart()
    }

    // `deinit` は書けない。`@MainActor` なクラスの `deinit` は nonisolated なので、
    // `timer` に触ると `main actor-isolated property 'timer' can not be referenced
    // from a nonisolated context` でコンパイルが通らない。タイマーは `[weak self]` を持つ
    // 非反復タイマーで、`stop()` と `restart()` が必ず無効化するため、取り残されても
    // 1 度発火して `self` が nil のまま何もしない。
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func restart() {
        stop()
        slot = 0
        hasFinished = false
        startedAt = CACurrentMediaTime()

        guard let clip, !isStill, clip.durations.count > 1 else { return }
        schedule()
    }

    private func schedule() {
        guard let clip else { return }

        let elapsed = CACurrentMediaTime() - startedAt
        slot = PetAnimation.slot(
            elapsed: elapsed, durations: clip.durations, repeats: clip.repeats
        )

        guard let boundary = PetAnimation.nextBoundary(
            after: elapsed, durations: clip.durations, repeats: clip.repeats
        ) else {
            if !hasFinished {
                hasFinished = true
                onFinished?()
            }
            return
        }

        // 「今から何秒後」ではなく再生開始からの絶対時刻で決めるので、誤差が累積しない。
        // tolerance は既定の 0 のまま。0.02 でも 5 秒で 1 割ずれる。
        // Timer.scheduledTimer は .default モードにしか入らず、メニューを開いた瞬間に止まる。
        let fire = Timer(fire: Date(timeIntervalSinceNow: max(0, boundary - elapsed)),
                         interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        }
        fire.tolerance = 0
        RunLoop.main.add(fire, forMode: .common)
        timer = fire
    }
}
```

- [ ] **Step 4: 通ることを確認する**

```bash
xcodebuild test -project AgentPets.xcodeproj -scheme AgentPets \
  -destination 'platform=macOS' -only-testing:AgentPetsTests/PetAnimatorTests 2>&1 | tail -15
```

期待: 7 テストすべて passed。

- [ ] **Step 5: コミット**

```bash
git add AgentPets/PetAnimator.swift AgentPetsTests/PetAnimatorTests.swift
git commit -m "$(cat <<'EOF'
Play an animation clip

The timer is rescheduled per frame because the contract gives each frame
its own duration. It goes on the run loop's common modes: a timer added
the default way stops the moment a menu opens, which is exactly when
someone is looking at the pet.

Fire times are computed from the start of playback rather than from now,
so the error does not accumulate, and the tolerance stays at zero — 0.02
drifts by a tenth over five seconds.

The timer block is nonisolated even with the module defaulting to
MainActor, and touching isolated state from it is only a warning. Going
through assumeIsolated makes that explicit without a hop per frame.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: 描画 — スプライト、吹き出し、絵文字への退避

スプライトは独立した `View` にする。親の `body` でフレーム番号を読むと、毎秒 5〜8 回の更新で
吹き出しまで再評価される。

`ContentView` は `message` が空なら吹き出しを描かない。ペットが選ばれていないか読み込めなければ、
これまでの絵文字表示に落ちる。

**Files:**
- Create: `AgentPets/SpeechBubble.swift`
- Create: `AgentPets/PetSpriteView.swift`
- Modify: `AgentPets/ContentView.swift`
- Test: `AgentPetsTests/PetDisplayTests.swift`

**Interfaces:**
- Consumes: `PetLibrary` / `Pet`（Task 5）、`PetAnimator`（Task 6）、`PetAnimation`（Task 4）、
  `SpriteSheet`（Task 3）
- Produces:
  - `SpeechBubble`（`init(message: String)`）
  - `PetSpriteView`（`init(sheet: SpriteSheet, manifest: PetManifest, state: PetState, eventID: Int)`）
  - `PetDisplay.mode(sheet: SpriteSheet?) -> PetDisplay.Mode`（`.sprite` / `.emoji`）

- [ ] **Step 1: 失敗するテストを書く**

`AgentPetsTests/PetDisplayTests.swift`:

```swift
//
//  PetDisplayTests.swift
//  AgentPetsTests
//

import Testing
@testable import AgentPets

@Suite("PetDisplay")
struct PetDisplayTests {

    @Test("シートが無ければ絵文字に落ちる")
    func fallsBackToEmoji() {
        #expect(PetDisplay.mode(sheet: nil) == .emoji)
    }

    @Test("吹き出しはメッセージが空なら出さない")
    func hidesEmptyBubble() {
        #expect(PetDisplay.showsBubble(message: "") == false)
        #expect(PetDisplay.showsBubble(message: "   ") == false)
        #expect(PetDisplay.showsBubble(message: "ビルド中") == true)
    }
}
```

`.sprite` を返す側は `SpriteSheet` の生成が要るので、Task 3 の
`SpriteSheetTests.makeAtlas` と同じ手順でアトラスを作ってから確かめる。次のテストを同じ
スイートに足す。

```swift
    @Test("シートがあればスプライトを出す")
    func usesSpriteWhenLoaded() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("atlas-\(UUID().uuidString).png")
        let context = try #require(CGContext(
            data: nil, width: 1536, height: 1872, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))

        let sheet = try SpriteSheet.load(contentsOf: url, frame: nil)

        #expect(PetDisplay.mode(sheet: sheet) == .sprite)
    }
```

このテストは `import CoreGraphics` / `import Foundation` / `import ImageIO` /
`import UniformTypeIdentifiers` を足す。

- [ ] **Step 2: 失敗することを確認する**

```bash
xcodebuild test -project AgentPets.xcodeproj -scheme AgentPets \
  -destination 'platform=macOS' -only-testing:AgentPetsTests/PetDisplayTests 2>&1 | tail -20
```

期待: `cannot find 'PetDisplay' in scope` でコンパイルエラー。

- [ ] **Step 3: 吹き出しを切り出す**

`AgentPets/SpeechBubble.swift`:

```swift
//
//  SpeechBubble.swift
//  AgentPets
//

import SwiftUI

/// ペットの上に出す吹き出し。表示するかどうかは呼び出し側が決める。
struct SpeechBubble: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.black)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
            )
            .lineLimit(2)
            .multilineTextAlignment(.center)
    }
}
```

- [ ] **Step 4: 表示の判定を切り出す**

`AgentPets/PetSpriteView.swift`（判定とスプライトを 1 ファイルに置く）:

```swift
//
//  PetSpriteView.swift
//  AgentPets
//

import SwiftUI

/// 何をどう出すかの判定。`body` に埋めるとテストできないので関数にしてある。
nonisolated enum PetDisplay {
    enum Mode: Equatable { case sprite, emoji }

    static func mode(sheet: SpriteSheet?) -> Mode {
        sheet == nil ? .emoji : .sprite
    }

    static func showsBubble(message: String) -> Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// スプライトの描画。
///
/// 親と分けてあるのは依存追跡のため。`ContentView` の `body` でフレーム番号を読むと、
/// 毎秒 5〜8 回の更新のたびに吹き出しまで再評価される。
struct PetSpriteView: View {
    let sheet: SpriteSheet
    let manifest: PetManifest
    let state: PetState
    /// 同じ状態が連続で届いてもやり直せるように、値そのものではなく連番で見る。
    let eventID: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animator = PetAnimator()

    var body: some View {
        Group {
            if let index = animator.frameIndex, let image = sheet.frame(at: index) {
                // scale: 2 にすると Retina で 192×208 が 96×104 pt に 1:1 で乗る。
                Image(decorative: image, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .onAppear {
            animator.isStill = reduceMotion
            animator.onFinished = { advanceAfterOneShot() }
            play(state)
        }
        .onChange(of: eventID) { play(state) }
        .onChange(of: reduceMotion) { animator.isStill = reduceMotion }
        .onDisappear { animator.stop() }
    }

    private func play(_ state: PetState) {
        animator.play(PetAnimation.clip(for: state, manifest: manifest, sheet: sheet))
    }

    /// success は跳ねたあと待機に戻る。error は落ち込んだまま留まる。
    private func advanceAfterOneShot() {
        guard let next = PetAnimation.stateAnimations[state]?.then else { return }
        play(next)
    }
}
```

- [ ] **Step 5: ContentView を組み替える**

`AgentPets/ContentView.swift` を次の内容にする。

```swift
//
//  ContentView.swift
//  AgentPets
//

import SwiftUI

struct ContentView: View {
    // @Observable なので、@State で包まなくても body からの参照が追跡される。
    // 生成は AppDelegate 側なので、ここで所有権を持たせてはいけない。
    let viewModel: PetViewModel
    let library: PetLibrary

    var body: some View {
        VStack(spacing: 8) {
            if PetDisplay.showsBubble(message: viewModel.message) {
                SpeechBubble(message: viewModel.message)
            }

            switch PetDisplay.mode(sheet: library.sheet) {
            case .sprite:
                if let sheet = library.sheet, let pet = library.selection {
                    PetSpriteView(
                        sheet: sheet,
                        manifest: pet.manifest,
                        state: viewModel.currentState,
                        eventID: viewModel.eventID
                    )
                }
            case .emoji:
                emojiPet
            }
        }
        .frame(minWidth: 96, minHeight: 104)
        .background(Color.clear)
    }

    /// ペットが選ばれていないか、アトラスを読めなかったときの表示。
    ///
    /// パルスはこちらにだけ残す。スプライト表示はアトラスが動きを持っているので要らないが、
    /// 絵文字表示にはこれしか動きが無く、初回起動時は全員がこの経路を通る。
    private var emojiPet: some View {
        Text(viewModel.currentState.emoji)
            .font(.system(size: 28))
            .padding(16)
            .background(
                Circle()
                    .fill(viewModel.currentState.color.opacity(0.85))
                    .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: 3)
            )
            .scaleEffect(viewModel.currentState == .working ? 1.1 : 1.0)
            .animation(
                .easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                value: viewModel.currentState == .working
            )
    }
}
```

`library.sheet` と `viewModel.eventID` はこの時点でまだ存在しない。Task 9 で `eventID` を、
このタスクの Step 6 で `sheet` を足す。

- [ ] **Step 6: PetLibrary にシートを持たせる**

`AgentPets/PetLibrary.swift` の `PetLibrary` に次を足す。`selection` が変わったら読み直す。
デコードは `nonisolated` な `SpriteSheet.load` を `Task.detached` で呼び、MainActor を空ける。

```swift
    private(set) var sheet: SpriteSheet?

    /// 選択中のペットのアトラスを読む。読めなければ nil のままにして、絵文字表示に落とす。
    private func loadSheet(for pet: Pet?) {
        sheet = nil
        guard let pet, let url = pet.manifest.spritesheetURL(in: pet.packageURL) else { return }

        let frame = pet.manifest.frame
        let id = pet.id
        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                try? SpriteSheet.load(contentsOf: url, frame: frame)
            }.value

            // 読み込んでいる間に選択が変わっていたら捨てる。
            // 先に始めた読み込みが後に終わると、選択とシートが食い違う。
            guard self.selection?.id == id else { return }
            self.sheet = loaded
        }
    }
```

呼ぶのは `select(_:)` の末尾と、`restore()` の `selection` 決定後の 2 か所だけ。

`adopt(_:)` からは呼ばない。`adopt` は `selection` を書き換えないので、その時点の
`selection` は古いままで、`setFolder` 経路では直後の `select(pets.first)` が始める
正しい読み込みを、古い方が後から nil で上書きしうる。フォルダを変える経路は
`setFolder` も `restore()` も最終的に選択が決まってから読み込む形になるので、
2 か所で漏れは無い。

- [ ] **Step 7: AppDelegate に library を渡す**

`AgentPets/AgentPetsApp.swift` の `AppDelegate` を次のようにする。

```swift
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let viewModel = PetViewModel()
    let library = PetLibrary()
    private var windowController: FloatingWindowController?
    private var listener: StatusNotificationListener?

    func applicationDidFinishLaunching(_ notification: Notification) {
        library.restore()

        let controller = FloatingWindowController(
            rootView: ContentView(viewModel: viewModel, library: library)
        )
        controller.showWindow(nil)
        windowController = controller

        let listener = StatusNotificationListener(viewModel: viewModel)
        listener.start()
        self.listener = listener
    }
}
```

`ContentView` の `#Preview` は `ContentView(viewModel: PetViewModel(), library: PetLibrary())` に直す。

- [ ] **Step 8: 全テストを通す**

```bash
xcodebuild test -project AgentPets.xcodeproj -scheme AgentPets -destination 'platform=macOS' 2>&1 | tail -5
```

期待: `** TEST SUCCEEDED **`。`viewModel.eventID` が無いというエラーが出る場合は、
Task 9 を先に済ませてからここへ戻る。

- [ ] **Step 9: コミット**

```bash
git add AgentPets/SpeechBubble.swift AgentPets/PetSpriteView.swift \
        AgentPets/ContentView.swift AgentPets/PetLibrary.swift \
        AgentPets/AgentPetsApp.swift AgentPetsTests/PetDisplayTests.swift
git commit -m "$(cat <<'EOF'
Draw the pet as a sprite, falling back to the emoji

The sprite lives in its own view so the frame index is read there and
nowhere else. Reading it from ContentView's body would re-evaluate the
speech bubble five to eight times a second for no reason.

The bubble is now a type of its own and is skipped entirely when the
message is empty, which is what idle sends. Whether to draw a sprite at
all, and whether to draw a bubble, are plain functions rather than
conditions buried in a body, so both are covered by tests.

Atlas decoding runs off the main actor. The module defaults to MainActor
isolation, so a 1536x1872 decode would otherwise stall the UI every time
the selected pet changes.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: メニュー — フォルダとペットを選ぶ

`MenuBarExtra` にフォルダ選択とペット一覧を足す。`NSOpenPanel` はメニュートラッキング中に
開くことになるので、`NSApp.activate()` を挟んで次の RunLoop に回す。

**Files:**
- Modify: `AgentPets/AgentPetsApp.swift`

**Interfaces:**
- Consumes: `PetLibrary`（Task 5）
- Produces: なし（UI の配線）

- [ ] **Step 1: メニューを組む**

`AgentPets/AgentPetsApp.swift` の `body` を次のようにする。

```swift
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
```

`panel.directoryURL` は設定しない。開始位置を特定の場所に向けると、そこを見に行く挙動になる。

- [ ] **Step 2: ビルドとテストを通す**

```bash
xcodebuild test -project AgentPets.xcodeproj -scheme AgentPets -destination 'platform=macOS' 2>&1 | tail -5
```

期待: `** TEST SUCCEEDED **`

- [ ] **Step 3: 手で確かめる**

```bash
xcodebuild build -project AgentPets.xcodeproj -scheme AgentPets \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath build >/dev/null
open build/Build/Products/Debug/AgentPets.app
```

順に確かめる。

1. メニューバーの足あとアイコンから「ペットフォルダを選択…」でパネルが前面に出る
2. ペットパッケージの入ったフォルダを選ぶと、一覧にペットが並ぶ
3. 選ぶとスプライトが出て、アニメーションする
4. `./scripts/agentpets-notify.sh working "テスト実行中"` で走るモーションに変わり、
   吹き出しが出る
5. `./scripts/agentpets-notify.sh idle` で吹き出しが消える
6. **メニューを開いたままにしてもアニメーションが止まらない**（`.common` モードの確認）
7. アプリを終了して再度起動すると、同じペットが選ばれた状態で出る
8. 「絵文字で表示」で以前の表示に戻る

- [ ] **Step 4: コミット**

```bash
git add AgentPets/AgentPetsApp.swift
git commit -m "$(cat <<'EOF'
Choose the pet folder and the pet from the menu

The open panel is opened on the next run loop pass after activating the
app. Running it modally from inside menu tracking can leave it behind
other windows.

The panel's starting directory is deliberately left alone. Pointing it
at a known location would make the app reach for somewhere the user
never named, which is the behaviour this design set out to avoid.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: イベント連番と RunLoop モード

`success` が 2 回続けて届いたとき、2 回目のジャンプを再生する。状態の値を比べる限り
変化が無いので、`apply()` のたびに増える連番を見る。

同じコミットで既存の `guardTimer` の RunLoop モードも直す。`working` 中にメニューを開いたまま
にするとウォッチドッグが遅れる。

**Files:**
- Modify: `AgentPets/PetViewModel.swift`
- Test: `AgentPetsTests/PetViewModelTests.swift`（既存に追加）

**Interfaces:**
- Consumes: なし
- Produces: `PetViewModel.eventID: Int`

- [ ] **Step 1: 失敗するテストを書く**

`AgentPetsTests/PetViewModelTests.swift` の `PetViewModelTests` に足す。

```swift
    @Test("applyのたびにイベント連番が増える")
    func incrementsEventID() {
        let viewModel = PetViewModel()
        let start = viewModel.eventID

        viewModel.apply(StatusPayload(state: .working, message: "1"))
        viewModel.apply(StatusPayload(state: .waiting, message: "2"))

        #expect(viewModel.eventID == start + 2)
    }

    @Test("同じ状態が連続してもイベント連番は増える")
    func incrementsEventIDOnRepeatedState() {
        let viewModel = PetViewModel()

        viewModel.apply(StatusPayload(state: .success, message: "done"))
        let first = viewModel.eventID
        viewModel.apply(StatusPayload(state: .success, message: "done"))

        #expect(viewModel.eventID == first + 1)
        #expect(viewModel.currentState == .success)
    }
```

- [ ] **Step 2: 失敗することを確認する**

```bash
xcodebuild test -project AgentPets.xcodeproj -scheme AgentPets \
  -destination 'platform=macOS' -only-testing:AgentPetsTests/PetViewModelTests 2>&1 | tail -20
```

期待: `value of type 'PetViewModel' has no member 'eventID'` でコンパイルエラー。

- [ ] **Step 3: 実装する**

`AgentPets/PetViewModel.swift` を次のようにする。

```swift
//
//  PetViewModel.swift
//  AgentPets
//

import Foundation
import Observation

@MainActor
@Observable
final class PetViewModel {
    var currentState: PetState = .idle
    var message: String = ""

    /// 通知を受け取るたびに増える。
    ///
    /// エージェントのフックは同じ状態を連投する（ツール呼び出しごとに success を送るなど）。
    /// 状態の値だけを見ていると 2 回目以降の変化を拾えず、跳ねる動きが 1 度しか出ない。
    private(set) var eventID = 0

    private var guardTimer: Timer?

    /// working のまま音沙汰が無くなったときに idle へ戻すまでの秒数
    var workingTimeout: TimeInterval = 10

    func apply(_ payload: StatusPayload) {
        currentState = payload.state
        message = payload.message
        eventID &+= 1

        guardTimer?.invalidate()
        guard payload.state == .working else { return }

        // working のまま通知が途絶えた場合に備え、一定時間で idle へ戻す。
        // .common モードに入れないと、メニューを開いている間だけ時間が進まない。
        let timer = Timer(fire: Date(timeIntervalSinceNow: workingTimeout),
                          interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.currentState == .working else { return }
                self.apply(StatusPayload(state: .idle, message: ""))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        guardTimer = timer
    }
}
```

- [ ] **Step 4: 通ることを確認する**

```bash
xcodebuild test -project AgentPets.xcodeproj -scheme AgentPets \
  -destination 'platform=macOS' -only-testing:AgentPetsTests/PetViewModelTests 2>&1 | tail -15
```

期待: 既存 4 件と新規 2 件の 6 テストすべて passed。

- [ ] **Step 5: コミット**

```bash
git add AgentPets/PetViewModel.swift AgentPetsTests/PetViewModelTests.swift
git commit -m "$(cat <<'EOF'
Count notifications so repeats replay

Agent hooks send the same status over and over — success after every
tool call, working before every one. Watching currentState alone means
the second success is indistinguishable from the first, and the jump
animation plays once and never again.

A counter that moves on every apply gives the view something that always
changes, without currentState having to mean anything other than "the
last state we were sent".

The watchdog timer moves to the run loop's common modes at the same
time. It had the same flaw the animation timer would have had: holding a
menu open froze it.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: 全体を通した確認

第 1 段階と第 2 段階が組み上がった状態を、実素材で確かめる。

**Files:** なし（確認のみ）

- [ ] **Step 1: 全テストを実行する**

```bash
xcodebuild test -project AgentPets.xcodeproj -scheme AgentPets -destination 'platform=macOS' 2>&1 | tail -30
```

期待: `** TEST SUCCEEDED **`。ベースラインの 13 件に対し 45 件前後になる。

- [ ] **Step 2: 5 つの状態を順に送って見た目を確かめる**

```bash
xcodebuild build -project AgentPets.xcodeproj -scheme AgentPets \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath build >/dev/null
open build/Build/Products/Debug/AgentPets.app
sleep 2
for s in idle working waiting success error; do
  ./scripts/agentpets-notify.sh "$s" "$s の表示"
  sleep 3
done
```

確かめること。

- `idle` は落ち着いた呼吸のループ
- `working` は作業中のループ
- `waiting` は問いかける姿勢のループ
- `success` は 1 回跳ねてから `idle` のループに落ちる
- `error` は 1 周して落ち込んだまま止まる

- [ ] **Step 3: 同じ状態の連投を確かめる**

```bash
./scripts/agentpets-notify.sh success "1回目"
sleep 2
./scripts/agentpets-notify.sh success "2回目"
```

2 回目も跳ねること。跳ねなければ Task 9 の連番が `PetSpriteView` まで届いていない。

- [ ] **Step 4: 動きを減らす設定を確かめる**

システム設定のアクセシビリティで「視差効果を減らす」を有効にし、アプリを起動し直す。
アニメーションが止まり、各状態の先頭フレームが出ること。確認後は設定を戻す。

- [ ] **Step 5: 壊れたパッケージへの反応を確かめる**

```bash
TMP=$(mktemp -d)
mkdir -p "$TMP/broken"
printf '{ "id": "broken", "displayName": "Broken", "description": "d", "spritesheetPath": "missing.webp" }' \
  > "$TMP/broken/pet.json"
echo "$TMP"
```

このフォルダを選び、`broken` を選んだときに絵文字表示に落ちること。アプリが落ちないこと。

---

### Task 11: ドラッグでのリサイズと位置の復元

パネルにリサイズを足す。`contentAspectRatio` は使わない。吹き出しの有無で高さが変わるため、
全体に比を掛けるとスプライトの取り分が削られる。比の維持は `PetSpriteView` の
`.aspectRatio(contentMode: .fit)` が担う。

掴み代は辺 3 pt・隅 12〜15 pt しかないので、右下隅を主な掴みどころにする。

**Files:**
- Modify: `AgentPets/FloatingWindowController.swift`
- Test: `AgentPetsTests/WindowFrameTests.swift`

**Interfaces:**
- Consumes: なし
- Produces: `WindowFrame.clamp(_ rect: NSRect, min: NSSize, max: NSSize, within: NSRect) -> NSRect`

- [ ] **Step 1: 失敗するテストを書く**

`AgentPetsTests/WindowFrameTests.swift`:

```swift
//
//  WindowFrameTests.swift
//  AgentPetsTests
//

import AppKit
import Testing
@testable import AgentPets

@Suite("WindowFrame")
struct WindowFrameTests {

    private let minimum = NSSize(width: 96, height: 104)
    private let maximum = NSSize(width: 384, height: 416)
    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)

    @Test("下限より小さいサイズを引き上げる")
    func raisesTooSmall() {
        let clamped = WindowFrame.clamp(
            NSRect(x: 100, y: 100, width: 20, height: 20),
            min: minimum, max: maximum, within: screen
        )

        #expect(clamped.width == 96)
        #expect(clamped.height == 104)
    }

    @Test("上限より大きいサイズを切り詰める")
    func lowersTooLarge() {
        let clamped = WindowFrame.clamp(
            NSRect(x: 100, y: 100, width: 5000, height: 5000),
            min: minimum, max: maximum, within: screen
        )

        #expect(clamped.width == 384)
        #expect(clamped.height == 416)
    }

    @Test("画面の外に出た位置を引き戻す")
    func pullsBackOffscreen() {
        let clamped = WindowFrame.clamp(
            NSRect(x: 9000, y: -500, width: 96, height: 104),
            min: minimum, max: maximum, within: screen
        )

        #expect(screen.contains(clamped))
    }

    @Test("収まっている矩形はそのまま返す")
    func keepsValidFrame() {
        let rect = NSRect(x: 200, y: 300, width: 120, height: 130)

        #expect(WindowFrame.clamp(rect, min: minimum, max: maximum, within: screen) == rect)
    }
}
```

- [ ] **Step 2: 失敗することを確認する**

```bash
xcodebuild test -project AgentPets.xcodeproj -scheme AgentPets \
  -destination 'platform=macOS' -only-testing:AgentPetsTests/WindowFrameTests 2>&1 | tail -20
```

期待: `cannot find 'WindowFrame' in scope` でコンパイルエラー。

- [ ] **Step 3: 実装する**

`AgentPets/FloatingWindowController.swift` を次のようにする。

```swift
//
//  FloatingWindowController.swift
//  AgentPets
//

import SwiftUI

/// 保存した矩形を戻すときの補正。
///
/// `contentMinSize` と `contentMaxSize` はユーザー操作によるリサイズにしか効かず、
/// `setFrame` は 20×20 も画面外も素通しする。壊れた保存値や、外部ディスプレイを外した
/// あとの復元でおかしなウィンドウが出ないよう、ここで丸める。
nonisolated enum WindowFrame {
    static func clamp(_ rect: NSRect, min minimum: NSSize, max maximum: NSSize, within bounds: NSRect) -> NSRect {
        var result = rect
        result.size.width = Swift.min(Swift.max(rect.width, minimum.width), maximum.width)
        result.size.height = Swift.min(Swift.max(rect.height, minimum.height), maximum.height)
        result.origin.x = Swift.min(Swift.max(result.origin.x, bounds.minX), bounds.maxX - result.width)
        result.origin.y = Swift.min(Swift.max(result.origin.y, bounds.minY), bounds.maxY - result.height)
        return result
    }
}

/// ペットを載せる、枠なし・背景透過・常に最前面のパネル。
/// 非アクティブなまま操作できるよう `.nonactivatingPanel` にしてある。
final class FloatingWindowController: NSWindowController {
    static let defaultContentSize = NSSize(width: 96, height: 104)
    static let maximumContentSize = NSSize(width: 384, height: 416)
    private static let frameKey = "petWindowFrame"

    convenience init<Content: View>(rootView: Content) {
        let panel = NSPanel(
            contentRect: NSRect(origin: CGPoint(x: 100, y: 100), size: Self.defaultContentSize),
            // .resizable を足すと、枠が無くても辺 3pt・隅 12〜15pt がリサイズ帯になる。
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentMinSize = Self.defaultContentSize
        panel.contentMaxSize = Self.maximumContentSize

        panel.contentView = NSHostingView(rootView: rootView)

        self.init(window: panel)
        restoreFrame()
    }

    /// 既定のサイズに戻す。位置はそのまま。
    func resetSize() {
        guard let window else { return }
        var frame = window.frame
        frame.size = window.frameRect(forContentRect: NSRect(origin: .zero, size: Self.defaultContentSize)).size
        window.setFrame(frame, display: true, animate: true)
        saveFrame()
    }

    func saveFrame() {
        guard let window else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.frameKey)
    }

    private func restoreFrame() {
        guard let window,
              let saved = UserDefaults.standard.string(forKey: Self.frameKey) else { return }

        let bounds = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        guard !bounds.isEmpty else { return }

        window.setFrame(
            WindowFrame.clamp(
                NSRectFromString(saved),
                min: Self.defaultContentSize,
                max: Self.maximumContentSize,
                within: bounds
            ),
            display: false
        )
    }
}
```

- [ ] **Step 4: 移動とリサイズを保存する**

`FloatingWindowController` を `NSWindowDelegate` にして、`windowDidResize` と `windowDidMove` で
`saveFrame()` を呼ぶ。`convenience init` の末尾で `panel.delegate = self` を設定する
（`self.init(window:)` のあとに書く）。

```swift
extension FloatingWindowController: NSWindowDelegate {
    func windowDidResize(_ notification: Notification) { saveFrame() }
    func windowDidMove(_ notification: Notification) { saveFrame() }
}
```

- [ ] **Step 5: メニューに「サイズを既定に戻す」を足す**

`AgentPetsApp.swift` の `AppDelegate` の `windowController` を `private` から
`private(set)` に変え、メニューの Quit の直前に足す。

```swift
            Button("サイズを既定に戻す") { appDelegate.windowController?.resetSize() }
```

- [ ] **Step 6: 通ることを確認する**

```bash
xcodebuild test -project AgentPets.xcodeproj -scheme AgentPets -destination 'platform=macOS' 2>&1 | tail -5
```

期待: `** TEST SUCCEEDED **`

- [ ] **Step 7: 手で確かめる**

```bash
xcodebuild build -project AgentPets.xcodeproj -scheme AgentPets \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath build >/dev/null
open build/Build/Products/Debug/AgentPets.app
```

1. ウィンドウの右下隅にポインタを合わせるとカーソルが変わり、ドラッグでリサイズできる
2. リサイズしてもペットの縦横比が崩れない
3. 中央をドラッグするとウィンドウが動く
4. アプリを終了して起動し直すと、サイズと位置が戻る
5. 「サイズを既定に戻す」で 96×104 に戻る

隅を掴めない場合は、`contentMinSize` を一時的に 200×216 に上げて掴み代が広がるか試す。
広がるなら、既定サイズでの掴みにくさが原因なので、右下に見えるグリップを描く必要がある。

- [ ] **Step 8: コミット**

```bash
git add AgentPets/FloatingWindowController.swift AgentPets/AgentPetsApp.swift \
        AgentPetsTests/WindowFrameTests.swift
git commit -m "$(cat <<'EOF'
Let the pet window be resized and remember where it was

.resizable on a borderless panel still gives real resize tracking areas:
three points along each edge, twelve to fifteen at the corners. At the
default 96x104 the edges are too thin to find, so the bottom-right
corner is the one to reach for.

contentAspectRatio is deliberately not used. It constrains the whole
content view, and the bubble comes and goes above the sprite, so the
bubble's height would be taken out of the sprite's. The sprite keeps its
own ratio instead.

Restored frames are clamped by hand. contentMinSize and contentMaxSize
only apply to user resizing — setFrame will happily place a 20x20 window
off screen, which is what a stale saved value or an unplugged display
would produce.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 12: README を更新する

**Files:**
- Modify: `README.md`

- [ ] **Step 1: 状態の表に行を足す**

`README.md` の状態表（9〜15 行目）を次に差し替える。

```markdown
| status    | スプライト | 絵文字表示       | 色       |
| --------- | ---------- | ---------------- | -------- |
| `idle`    | idle       | 🟢 `(・ω・)`      | グリーン |
| `working` | running    | ⚡ `(•̀ᴗ•́)و`      | イエロー |
| `waiting` | waiting    | ❓ `(･_･;)`       | オレンジ |
| `success` | jumping    | 🎉 `(٩(ˊxDˋ*)و)` | ブルー   |
| `error`   | failed     | 💥 ``(´;ω;`)``   | レッド   |

`success` は 1 度跳ねてから `idle` に戻る。`error` は落ち込んだまま次の通知を待つ。
ペットが未設定のとき、およびアトラスを読めなかったときは絵文字表示になる。
```

- [ ] **Step 2: ペットの節を足す**

「状態を送る」の節の前に次を足す。

```markdown
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
```

- [ ] **Step 3: セキュリティの節を直す**

`README.md` の「App Sandbox 有効のまま動作し、追加の entitlement を必要としない。」を含む
段落を次に差し替える。

```markdown
**待ち受けポートを持たない。** HTTP サーバーのようにポートを開かないので、
ブラウザで開いたページなどアプリ外から到達できる経路が生まれない。

**ファイルへの権限は 2 つ。** App Sandbox を有効にしたまま、
`com.apple.security.files.user-selected.read-only` と
`com.apple.security.files.bookmarks.app-scope` を使う。前者は選択パネルで選ばれたものを
読むため、後者はその許可を次回起動以降も保つため。結果として、一度選んだフォルダは
再許可なしで読み続けられる。読み取りのみで、書き込みはしない。

既知の場所を推測して探すことはしない。ユーザーが選んでいないフォルダには触れない。
```

- [ ] **Step 4: テストの節を直す**

「テスト」の節の説明文を次に差し替える。

```markdown
ペイロードの解析、不正入力の拒否、`working` のウォッチドッグ、通知センター経由の受信に加え、
`pet.json` の解析、アトラスの寸法検証、フレーム番号の算出、アニメーションの進み方、
ペットパッケージの探索、ウィンドウ矩形の補正までを含む。
```

- [ ] **Step 5: 記述と実装が合っているか確かめる**

README が名指ししているファイル・パス・entitlement 名を、実際のコードと突き合わせる。

```bash
codesign -d --entitlements :- build/Build/Products/Debug/AgentPets.app 2>/dev/null
grep -n "pet.json" AgentPets/PetLibrary.swift
```

- [ ] **Step 6: コミット**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
Document the sprite pets

The security section said the app needs no extra entitlements, which was
already only true of the one it shipped with. It now uses two, so say
which two and what they buy: a folder the user picks once stays readable
across launches.

Say plainly that the app does not go looking for pets on its own. Where
hatch-pet writes them is useful to know, and is exactly the kind of path
a reader would otherwise assume the app reads by itself.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## 完了の条件

- `xcodebuild test -project AgentPets.xcodeproj -scheme AgentPets -destination 'platform=macOS'` が
  `** TEST SUCCEEDED **` を返す
- `codesign -d --entitlements :- build/Build/Products/Debug/AgentPets.app` に
  `com.apple.security.files.bookmarks.app-scope` が入っている
- 実素材のペットを選び、5 つの状態すべてでアニメーションが出る
- 同じ状態を連投しても毎回再生される
- メニューを開いたままでもアニメーションが止まらない
- アプリを起動し直すと、フォルダ・ペット・ウィンドウの位置とサイズが復元される
- ペット未設定と読み込み失敗のとき、絵文字表示に落ちる
- `~/.codex` を参照するコードがリポジトリに 1 行も無い（`grep -rn "\.codex" AgentPets/` が空）
