# スプライトアニメーション対応 設計

2026-08-15

ペットの表示を、固定の絵文字から、Codex の hatch-pet スキルが生成するスプライトアトラスの
アニメーションに置き換える。

## 背景

現在のペットは `PetState.emoji` と `PetState.color` で描かれている。状態は
`idle` / `working` / `waiting` / `success` / `error` の 5 つで、外部プロセスから
`DistributedNotificationCenter` 経由で届く。

素材として使うのは、`pet.json` と `spritesheet.webp` の 2 ファイルからなるペットパッケージ。
hatch-pet はこれを `${CODEX_HOME:-$HOME/.codex}/pets/<name>/` に出力する。

## 前提として確かめたこと

### アトラスの仕様

hatch-pet の `references/codex-pet-contract.md` と `references/animation-rows.md` が仕様。

1536×1872、8 列 × 9 行、セル 192×208、未使用セルは完全透過。行と各フレームの表示時間は次のとおり。

| 行 | 名前 | 使用列 | 表示時間 |
| --- | --- | --- | --- |
| 0 | idle | 0-5 | 280, 110, 110, 140, 140, 320 ms |
| 1 | running-right | 0-7 | 120 ms ×7 ＋ 220 ms |
| 2 | running-left | 0-7 | 120 ms ×7 ＋ 220 ms |
| 3 | waving | 0-3 | 140 ms ×3 ＋ 280 ms |
| 4 | jumping | 0-4 | 140 ms ×4 ＋ 280 ms |
| 5 | failed | 0-7 | 140 ms ×7 ＋ 240 ms |
| 6 | waiting | 0-5 | 150 ms ×5 ＋ 260 ms |
| 7 | running | 0-5 | 120 ms ×5 ＋ 220 ms |
| 8 | review | 0-5 | 150 ms ×5 ＋ 280 ms |

手元にある 3 つのパッケージ（zundamon / zundamon-pixel / moka）のアトラスについて、
セルごとにアルファチャンネルを全ピクセル走査して使用列を数えたところ、3 つとも上の表と
完全に一致した。未使用セルは最大アルファが 0 で、透過ピクセルの RGB も 0 に正規化されていた。

### 画像のデコード

ImageIO は WebP を直接読める（`org.webmproject.webp`）。1536×1872、8 bpc / 32 bpp、
`alphaInfo` は `.last`（非乗算アルファ）、色空間は sRGB。外部ライブラリは要らない。

非乗算アルファのまま描いて縁にフリンジが出ないかを確認した。同じピクセルから `.last` 版と
`.premultipliedLast` 版の `CGImage` を作り、等倍・96×104 への縮小・384×416 への拡大の 3 通りを、
補間 3 種類と白背景・黒背景の組み合わせで描き比べたところ、全ケースでバイト単位で同一だった。
CoreGraphics が内部で乗算してからリサンプルしている。

`cropping(to:)` で切り出したセルは、親のバッファを共有しない。`dataProvider` は 31 セルすべてで
親と別物になり、`bytesPerRow` も 768（= 192×4）で親の 6144 とは一致しない。切り出し自体は遅延で、
実体化すると各セルが自前のバッファを持つ。アトラス 11 MiB ＋ セル最大 4 MiB で、合計は約 15 MB。
この規模なら保持して構わない。

### サンドボックス

現行ビルドの entitlement は `com.apple.security.app-sandbox` と
`com.apple.security.files.user-selected.read-only`（`codesign -d --entitlements` で確認）。
`project.pbxproj` には `ENABLE_APP_SANDBOX = YES` があり、`.entitlements` ファイルは無い。

Xcode 27 のビルド設定には security-scoped bookmark に対応するものが無い（ビルド設定の定義を
機械的に列挙して、名前に `BOOKMARK` を含むものが 0 件であることを確認した）。したがって
`.entitlements` ファイルを新設する。

`CODE_SIGN_ENTITLEMENTS` を設定してもビルド設定由来の entitlement は消えない。プロジェクトを
複製して実際にビルドし、ファイルに `bookmarks.app-scope` だけを書いた場合でも署名結果に
3 つとも入ることを確認した。警告もエラーも出ない。

サンドボックス下でのホームディレクトリの扱いも確認した。`NSHomeDirectory()` と
`FileManager.default.homeDirectoryForCurrentUser` と `getenv("HOME")` はいずれもコンテナを指すが、
`getpwuid(getuid())->pw_dir` は実ホームを返す。実ホーム配下のパスに対して `fileExists` と `stat` は
成功し、`contentsOfDirectory` と `open()` は拒否される（NSCocoaError 257 / EPERM）。

**つまり、存在確認はできて読み取りだけができない。** 本設計では、実ホーム配下を参照する API を
一切呼ばない。これは技術的な制約ではなく意図的な選択で、理由は次項に書く。

### プロジェクト構造

`AgentPets/` と `AgentPetsTests/` は `PBXFileSystemSynchronizedRootGroup` なので、`.swift` を置くだけで
ビルド対象に入る。`.entitlements` を同じ場所に置いてもアプリバンドルにはコピーされない。
ただし `.json` と `.md` は `Contents/Resources/` に自動でコピーされるため、テストのフィクスチャを
ファイルとして置いてはいけない。

モジュール既定の分離は `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`。何も指定しない型は MainActor に
乗る。テストは `TEST_HOST` でホストアプリに注入され、Swift Testing を使っている。

## 設計方針

### ペットフォルダを自動では探さない

このアプリは、ユーザーが明示的に選んだフォルダ以外を一切見ない。起動直後の登録は空で、
メニューから選ぶまでファイルシステムに触れない。

前項のとおり、実ホームの `~/.codex/pets` が存在するかどうかは技術的には検知できる。それでも
検知しないのは、他のツールの設定ディレクトリを黙って覗く挙動が、常駐アプリとして正当化しにくい
ためである。hatch-pet の出力先は README に書くに留める。

### 通信仕様は変更しない

`StatusPayload` と `StatusNotificationListener` と `scripts/agentpets-notify.sh` は無変更。
状態は 5 つのまま。Claude Code・Codex CLI・Gemini CLI のいずれもフックからシェルを 1 行叩ける形式で、
承認待ち・完了・失敗に相当するイベントが揃っているので、5 状態で足りる。

### 状態と行の対応

| 状態 | 行 | 再生 |
| --- | --- | --- |
| idle | idle | ループ |
| working | running | ループ |
| waiting | waiting | ループ |
| success | jumping | 1 周してから idle のループへ |
| error | failed | 1 周して最終フレームで静止 |

`error` を idle に戻さないのは、失敗が視界から消えると状態表示として機能しないため。次の通知が
来るまで落ち込んだままにする。

使わないのは running-right / running-left / waving / review の 4 行。読み込みはするが再生しない。

## 所有と依存

```
AppDelegate（所有）
├── PetViewModel                状態と message。既存。変更は eventID の追加のみ
├── PetLibrary                  フォルダの bookmark、ペット一覧、選択中のペット、読み込み済みシート
├── FloatingWindowController
│   └── ContentView(viewModel:library:)
│       ├── SpeechBubble        message が空なら描かない
│       └── PetSpriteView(sheet:state:eventID:)
│           └── PetAnimator     @State で PetSpriteView が所有する
└── StatusNotificationListener  既存。無変更
```

`AppDelegate` が `PetViewModel` と `PetLibrary` を所有するのは、既存の
`AgentPetsApp.swift` のコメントに書かれている理由（Scene の body 評価中に `@State` へ書き戻すと
参照が保持されない）がそのまま当てはまるため。`MenuBarExtra` からも `AppDelegate` 経由で
`PetLibrary` に届く。

`PetAnimator` を `PetSpriteView` が `@State` で持つのは、親が animator を読まないようにするため。
`@Observable` の依存追跡は body で読んだプロパティに対して働くので、`ContentView` の body で
フレーム番号を読むと、毎秒 5〜8 回の更新で吹き出しまで再評価される。実測でも、スプライトを
別 View に切り出した場合は親と吹き出しの body 評価が 0 回、同じ body で両方を読んだ場合は
23 回だった。

## マニフェスト

`pet.json` の必須は 4 フィールド。これは hatch-pet の公開契約に載っている形。

```json
{
  "id": "zundamon",
  "displayName": "Zundamon",
  "description": "…",
  "spritesheetPath": "spritesheet.webp"
}
```

Codex CLI のバイナリには、これを拡張した内部モデルが入っている。`PetFile` が 6 フィールド
（4 つ ＋ `frame` ＋ `animations`）、`FrameSpec` が 4 フィールド（`width` / `height` / `columns` ＋ 1）、
`AnimationSpec` が 4 フィールド（`frames` / `fps` ＋ 2、うち 1 つは `fallback`）という構成で、
`animation X references sprite index N, but pet has M frames` のようなバリデーション文言も揃っている。

ただしこれはシンボル名からの推定であり、公開契約には載っていない。手元の 3 つのパッケージも
すべて 4 フィールドの最小形で、拡張形の実物は 1 つも無い。`FrameSpec` の 4 番目のフィールド名は
特定できなかった（`columns` と対になるのが行数なのかフレーム総数なのか、どちらの証拠もある）。

そこで次のように扱う。

- `frame` と `animations` は任意。無ければ固定契約（8×9 / 192×208 / 上の表の表示時間）を使う
- **あれば厳格に読む。** `animations` の各エントリに `frames` が無ければ、既定値に落とさず
  読み込み失敗にする。`frame` があれば `width` / `height` / `columns` を必須にする
- 名前を特定できていないフィールドは要求も参照もしない。行数は `シートの高さ ÷ height` で求め、
  割り切れなければ読み込み失敗にする
- 知らないキーは無視する

「無ければ既定値」を拡張形にも適用すると、フィールド名を取り違えていた場合に黙って既定値で
動いてしまい、誤読が表に出ない。厳格に読めば、取り違えは読み込み失敗として現れる。

`frames` は「行 × columns ＋ 列」の平面インデックスとして解釈する。これも推定である。

`spritesheetPath` はパッケージからの相対パスとして解決し、パッケージ外を指すものは拒否する。
解決にはパッケージのベース URL が要るので、デコード側ではなく呼び出し側に置く。

`~/.codex/avatars/<name>/avatar.json` という第 2 の置き場が Codex CLI には存在するようだが、
中身を確認できていないので対象外とする。このアプリが読むのは `pet.json` を持つディレクトリだけ。

## フォルダの登録

参照先は 1 フォルダ。`Data` 1 個の security-scoped bookmark を `UserDefaults` に持つ。

- メニューの「ペットフォルダを選択…」から `NSOpenPanel` を出す。ディレクトリのみ、複数選択なし、
  隠しファイルを表示する。開始位置は指定せず、パネル自身の既定に任せる
- bookmark は `.withSecurityScope` を付けて作り、解決時も `.withSecurityScope` を渡す。
  読み取りしかしないので `.securityScopeAllowOnlyReadAccess` も付ける
- `startAccessingSecurityScopedResource()` はフォルダごとに 1 回だけ呼ぶ。`false` が返った場合は
  対応する `stop` を呼ばない
- フォルダを変更したときに、古い方の `stop` を呼ぶ。アプリ終了時の `stop` は書かない
  （プロセスが終わるため意味がない）
- stale になった bookmark は再生成する。解決できないものは「見つかりません」として表示し、
  選び直せるようにする
- 走査は登録フォルダ直下 1 階層のみ。`pet.json` を持つディレクトリをペットとみなす

`NSOpenPanel` はメニュートラッキング中に開くことになるので、`NSApp.activate()` を挟み、
モーダル表示は次の RunLoop に回す。このアプリは `LSUIElement` を設定しておらず Dock に出る
通常のアプリなので、アクティブ化そのものは問題にならない。

選択中のペットは `id` で `UserDefaults` に保存する。

`AgentPets.entitlements` を新設し、**`com.apple.security.files.bookmarks.app-scope` だけ**を書く。
`app-sandbox` と `user-selected.read-only` はビルド設定側に残す。両方に書くと、同じ設定の
出どころが 2 か所になり、片方だけ変更したときに気づけない。

## シートの読み込み

`SpriteSheet` は `nonisolated` にして、デコードを MainActor の外で行う。モジュール既定が
MainActor なので、指定しないと 1536×1872 のデコードが UI スレッドで走り、起動時とペット切替時に
画面が止まる。`PetLibrary` のペット読み込み API は `async` になる。

`CGImageSourceCreateWithURL` から `CGImageSourceCreateImageAtIndex` で 1 枚読み、使う行の
フレームだけ `cropping(to:)` する。実寸が `columns × width` × `rows × height` と一致しなければ
読み込み失敗とし、そのペットは選べないようにする。

## 再生

### 解決済みのクリップ

状態・マニフェスト・固定契約の 3 つは、`PetAnimator` に渡る前に 1 つの値型へ畳む。
畳む関数は `AnimationClip.swift` に置き、`PetSpriteView` が呼ぶ。

```swift
struct AnimationClip {
    let frames: [CGImage]
    let durations: [TimeInterval]
    let repeats: Bool          // false ならクランプ
}
```

`PetAnimator` が知るのはこの型だけで、`PetState` にも `PetManifest` にも依存しない。
状態から行への対応表もアニメーション層に置く。`PetState` は通信仕様の enum なので、
表示の都合で増やさない（`emoji` と `color` は絵文字フォールバック用に残す）。

### フレーム番号は純粋関数で決める

```swift
func frameIndex(elapsed: TimeInterval, durations: [TimeInterval], repeats: Bool) -> Int
```

ループは合計時間で剰余を取り、クランプは最後のフレームで止める。時計に依存しないので、
テストは実時間を待たずに書ける。

「ループとワンショットの 2 層」という構造は要らない。`repeats` フラグ 1 つで足りる。

### 駆動

`PetAnimator` は現在のクリップと経過時間からフレーム番号を持ち、次のフレームまでの時間で
`Timer` を張り直す。更新は毎秒 5〜8 回。

- `Timer(timeInterval:repeats:block:)` を作り、`RunLoop.main.add(_:forMode: .common)` で登録する。
  `Timer.scheduledTimer` は `.default` モードにしか入らないため、メニューを開いている間と
  ウィンドウのドラッグ中に停止する（`.default` は 0 回、`.common` は 1 回発火することを実測）
- `tolerance` は既定の 0 のままにする。0.02 にすると 5.3 秒で 0.557 秒（約 10.5%）ずれた
- 次の発火時刻は「今」からではなく再生開始時刻からの絶対時刻で計算する
- クロージャは nonisolated なので、中身は `MainActor.assumeIsolated` で包む。
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` が効いていても警告止まりで、気づかず通ってしまう

既存の `PetViewModel` の `guardTimer` も `Timer.scheduledTimer` なので同じ問題がある。
`working` 中にメニューを開いたままにするとウォッチドッグが遅延するため、あわせて `.common` に直す。

### 再生のきっかけ

`PetViewModel` に単調増加のイベント連番を足し、`apply()` で必ず更新する。

`currentState` の等価比較に頼ると、同じ状態が連続で届いたときに再生が始まらない。エージェントの
フックは同じイベントを連投するのが普通で（`PostToolUse` ごとに `success` を送るなど）、
`success` が 2 回続いたときに 2 回目のジャンプが出ない。

ワンショットが終わっても `currentState` は書き換えない。`currentState` は「最後に受け取った
payload の state」という意味を保つ。README の通信仕様と 1 対 1 で、既存のテストもその契約で
書かれている。success のあと idle のループに移るのはアニメーション層の内部遷移として扱う。

### 動きを減らす設定

`NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` が有効なら、その状態のクリップの
先頭フレームで静止させる。変更通知は `NSWorkspace.shared.notificationCenter` に
`accessibilityDisplayOptionsDidChangeNotification` で登録する。`NotificationCenter.default` には
届かない（SDK のヘッダに明記されている）。

Codex の公開ドキュメントは「reduced motion が有効なときは静止フレームを使う」までしか書いておらず、
どのフレームかは書いていない。状態ごとに先頭フレームを選ぶのはこのアプリの判断である。

## ウィンドウと描画

既定のサイズは 96×104 pt。Retina では 192×208 ピクセルが 1 対 1 で出る。
`Image(decorative:scale: 2)` にすると補間が一切かからないことを実測で確認した
（1 ピクセル市松模様を描いて中間色の画素数を数えたところ 0.00%）。

- `contentAspectRatio` は使わない。吹き出しの有無でウィンドウの高さが変わるため、全体に比を
  掛けると吹き出しの高さがスプライトの取り分から引かれる（実測でウィンドウ全体が 0.9225 に
  矯正された）。代わりに SwiftUI 側で `.aspectRatio(192.0 / 208.0, contentMode: .fit)` を
  スプライトに掛ける。ウィンドウは透過なので、余った領域は見えない
- `styleMask` に `.resizable` を足す。`.borderless` でもリサイズは効き、カーソルも変わる。
  ただし掴み代は辺 3 pt・隅 12〜15 pt しかなく、96×104 では辺は実質使えない。右下隅を主な
  掴みどころとし、ポインタが乗っているときだけ薄いグリップを描いて位置を示す
- `isMovableByWindowBackground` とリサイズ帯は競合しない。リサイズの判定が先に走る
- `contentMinSize` と `contentMaxSize` を設定する。ただしこれらはユーザー操作によるリサイズにしか
  効かず、`setFrame` は矯正しない（500×100 も 20×20 もそのまま通る）。`UserDefaults` からの
  復元時は自前でクランプし、画面内に収まることも確認する
- サイズと位置を保存し、次回起動で復元する。メニューに「サイズを既定に戻す」を置く

リサイズすると表示倍率は整数倍でなくなる。補間は既定のままにする。既定サイズでは補間が
働かないので、ドット絵のペットも等倍では劣化しない。

吹き出しは `SpeechBubble` として切り出し、`message` が空なら描かない。現在は 12 行の
モディファイア列が `ContentView` の body に直接書かれているので、条件分岐を足す前に分ける。

ペットが未設定のときと読み込みに失敗したときは、現在の絵文字表示に落ちる。この判定は
body に埋めず、関数として切り出してテストできるようにする。

## メニュー

- ペット一覧（選択中にチェック）と「絵文字で表示」
- 「ペットフォルダを選択…」／「変更…」
- 「サイズを既定に戻す」

## テスト

Swift Testing で、UI に触れない層を対象にする。フィクスチャはファイルとして置かず、テスト内で
生成する（`AgentPets/` や `AgentPetsTests/` に置いた `.json` と `.md` は製品バンドルに入るため）。

- フレーム番号の純粋関数。ループの剰余、クランプ、境界（0、最終フレーム、合計時間ちょうど）
- `PetManifest`。4 フィールドの最小形、拡張形、`animations` があって `frames` が無い場合に
  読み込み失敗になること、知らないキーが無視されること、壊れた JSON
- `spritesheetPath` の解決。パッケージ外を指すものを拒否すること
- `SpriteSheet`。寸法不一致の拒否、行数が割り切れない場合の拒否、フレーム番号から矩形への変換
- 5 つの `PetState` すべてが、アトラス上に存在する行に対応すること（集合として比較する）
- 既定スケジュールのフレーム数と合計時間が、上の表と一致すること。表は 1 か所に置き、
  テストはそれを参照する（テスト内に表を書き写すと自己参照になる）
- 絵文字フォールバックに落ちる条件
- `PetLibrary`。`pet.json` を持つディレクトリを拾うことと、持たないディレクトリ・ファイル・
  2 階層目を拾わないこと
- `PetViewModel` のイベント連番が `apply()` のたびに増えること。同じ状態が連続しても増えること
- bookmark の保存と読み出し、stale の分岐。`bookmarkData` と `resolvingBookmarkData` の呼び出しは
  差し替えられる形に切っておく。`NSOpenPanel` が付与する本番の経路はテストで再現できないので、
  そこは手動確認とする

ダミーのアトラスは 8×9 の PNG をテスト内で生成して使う。実素材が無い環境でも通るようにする。

## 段階

一度に全部は作らない。

**第 1 段階** — entitlements、フォルダ選択、`PetManifest`、`SpriteSheet`、固定契約のスケジュール、
ループのみの再生、`PetSpriteView`、`SpeechBubble` の出し分け、絵文字フォールバック、
選択中ペットの保存。5 状態がそれぞれの行をループする。ここで単体で使える。

**第 2 段階** — success と error のクランプ、イベント連番によるきっかけ、動きを減らす設定への対応。
純粋関数にしてあるので、フラグの追加で済み新しいファイルは増えない。

**第 3 段階** — ドラッグでのリサイズ、サイズと位置の復元と復元時のクランプ、
「サイズを既定に戻す」。

## README への追記

- 状態と行の対応表
- ペットフォルダの選び方。hatch-pet の出力先が `${CODEX_HOME:-$HOME/.codex}/pets/` であることと、
  このアプリはそこを自動では見ないこと
- セキュリティの節の書き換え。現在は「追加の entitlement を必要としない」と書いてあるが、
  実際には `user-selected.read-only` が既に入っており、今回 `bookmarks.app-scope` が加わる。
  読者から見ると 0 から 2 に増える。増えた事実だけでなく、選んだフォルダに対して再許可なしで
  次回起動以降も読み取りアクセスを持つ、というところまで書く

## 新規ファイル

| ファイル | 責務 |
| --- | --- |
| `PetManifest.swift` | `pet.json` のデコード |
| `PetLibrary.swift` | フォルダの bookmark、ペットの列挙、選択中のペットの保持 |
| `SpriteSheet.swift` | アトラスのデコードとフレームの切り出し |
| `AnimationClip.swift` | 解決済みクリップと、フレーム番号を求める純粋関数 |
| `PetAnimator.swift` | クリップの再生 |
| `PetSpriteView.swift` | スプライトの描画 |
| `SpeechBubble.swift` | 吹き出し |
| `AgentPets.entitlements` | `bookmarks.app-scope` |

既存の変更は `ContentView.swift`（スプライトと絵文字の切替）、`PetViewModel.swift`
（イベント連番の追加と `guardTimer` の RunLoop モード）、`AgentPetsApp.swift`（メニュー）、
`FloatingWindowController.swift`（リサイズとサイズ・位置の復元）。`PetState.swift` は無変更。
