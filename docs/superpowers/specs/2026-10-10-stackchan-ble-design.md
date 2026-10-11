# StackChan BLE 表示 設計（第 2・3 期）

- 日付: 2026-10-10
- 状態: 承認済み（サブエージェントレビュー: 契約・Mac 側 APPROVE、ファームウェア・安全 APPROVE）
- 対象: AgentPets（第 2 期: BLE 出力）と新規 repo `~/work/tools/stackchan-pet`（第 3 期: StackChan ファームウェア）
- 前提: 第 1 期 `docs/superpowers/specs/2026-10-10-agent-event-hub-design.md`（実装済み、`c59b253`）

## 目的

AgentPets が集約した表示状態（5 状態、短い文、跳ねる合図）を BLE で StackChan K151 に送り、
首を動かさずに顔と短い文で見せる。ターミナルも Mac の画面も見ていないときに、机の上の StackChan で状態が分かることを目指す。

## 決定事項

| 決定 | 理由（ユーザー回答・調査） |
|---|---|
| 表示は目と口の顔を先に作り、スプライトは後から足せる形にする（C 案） | ユーザー回答 |
| 接続は BLE、Mac が central、StackChan が peripheral。iPhone は使わない | ユーザー回答 |
| wire は 1 characteristic に固定形式のバイナリを write without response で送る（案 1） | ユーザー回答。解析が数行で依存なし、MTU に確実に収まる |
| 未接続（切断・15 秒無受信）はニュートラルな表情 | ユーザー回答 |
| ファームウェアは UWB PoC と別 repo。土台（toolchain・BSP・パッチ）は PoC の固定版を写す | ユーザー回答（別プロジェクト、将来統合の可能性）。統合時に 1 つのスケッチへまとめやすい |
| ESP32 側にサーボ電源（VM）を ON にする経路を持たせず、起動時に OFF を書いて読み戻しで確かめる | 首は後回し（ユーザー回答）。OFF の書き込み ACK は I2C の ACK でしかなく（PoC `hardware-results.md:50`）、電源投入直後の VM 状態も未記録なので、「一度も ON にならない」とは主張しない |
| 第 3 期は単一接続 | 接続中も advertising を続けると、1 台の切断で未接続になる・第三者に枠を占有される等、§1.3/1.4 と矛盾するため。同時接続は統合時に設計する |

## 成功条件

1. AgentPets の表示が変わってから 1 秒以内に、StackChan の顔と状態の文が変わる。
2. 跳ねる合図（第 1 期 §2.3）で、StackChan も画面上で喜ぶ動きを 1 回する。keep-alive の送り直しや再接続では喜ばない。
   write without response は欠落しうる（届かなくても通知されない）ため、合図のレコードが落ちた場合は、
   状態が success のままなら次の keep-alive（最大 5 秒後）で遅れて喜び、それまでに別の状態へ変わっていれば喜ばない。これを許容する。
3. Mac から正しいレコードが 15 秒届かないか切断を検知したら、ニュートラルな顔と「未接続」になる。
4. このファームウェアは首を動かす経路を持たない。起動時にサーボ電源 OFF を書いて PY32 から読み戻して確かめ、確かめられなければ fault 表示にする（§3.4）。

## 1. wire contract（版 1）

### 1.1 GATT

- Service UUID: `B405CCEA-139A-4248-9CDE-5BAB2613D855`
- State characteristic UUID: `24EE255E-42EC-4702-AF9C-C8EF325929AC`。プロパティは write without response のみ（read・notify なし）。
- StackChan は Service UUID を advertise する。デバイス名は `StackChanPet`。
- Mac は、覚えた identifier があれば `retrievePeripherals(withIdentifiers:)` で取り出して connect を保留し、
  同時に Service UUID でスキャンする。先につながった方を使い、もう一方は取り消す（覚えた機体が無い・交換した場合に永久に待たないため）。
  スキャンで複数見つかったときは最初に見つかった 1 台を使う。接続した機体の名前と identifier をメニューに出し、identifier を覚え直す。対象は 1 台。

### 1.2 レコード

| バイト | 内容 | 値 |
|---|---|---|
| 0 | 版 | `1` |
| 1 | 状態 | 0 idle / 1 working / 2 waiting / 3 success / 4 error |
| 2 | 跳ねる番号 | 0〜255 で一周。Mac は `DisplayState.celebrate` が立つたびに 1 増やす |
| 3 | 文のバイト長 L | 全長−4（0〜255） |
| 4〜4+L−1 | 文（UTF-8） | `DisplayState.subtitle`（§2.1）。状態の語は含めない |

- 全長は `min(maximumWriteValueLength(for: .withoutResponse), 259)` 以下。259 は L が 1 バイトであることによる上限
  （`MessageText.limit` は 120 文字なので、日本語の文は UTF-8 で 255 バイトを超えうる）。最小 ATT MTU（23）では 20 バイト、文は 16 バイトまで。
- Mac は文を `Character` の切れ目で、UTF-8 のバイト数が収まるよう切り詰め、切ったときは末尾を `…`（3 バイト）にする。
- 状態の語（作業中・入力待ち・完了・失敗）と顔はファームウェアが状態値から決める。

### 1.3 受信規則（ファームウェア）

- 捨てるレコード: 全長 4 未満、版が 1 以外、状態が範囲外、L が残りバイト数と一致しない、文が UTF-8 として不正。
  捨てたときは表示を変えず、watchdog も延長しない。
- 跳ねる: 状態が success で、跳ねる番号が直前に受理したレコードの番号と違うときだけ。
  接続後に最初に受理したレコードは番号を覚えるだけで跳ねない（再接続のたびに跳ねないため）。
- 同じ内容のレコード（keep-alive）は watchdog を延長するだけで、描画をやり直さない。

### 1.4 生存確認

- Mac は接続中、characteristic を発見した直後・変化があったとき即時に、変化が無くても 5 秒ごとに最新レコードを送る。
  keep-alive の Timer は RunLoop の `.common` モードに登録する（メニューを開いている間も止めないため。第 1 期の `HubStore.start` と同じ理由）。
- StackChan は、正しいレコードが 15 秒届かないとき、または切断を検知したとき、ニュートラルな顔と「未接続」にする。
- 切断後は advertising を再開する。

### 1.5 安全と認証

- 書き込みに認証（ペアリング）は要求しない。第三者に起こせるのは表示の偽装と、先に接続して Mac の接続を妨げること（単一接続のため）だけで、首は動かないため。
- 近くに別の `StackChanPet` があると、スキャンで先に見つかった方を覚え直しうる。複数台は範囲外とし、メニューに出す名前と identifier で気づけるようにする。
- **首の動作を追加するときは、bonding による認証と、動作コマンドの別 characteristic 化を必須とする**（本 spec の範囲外の前提条件）。

## 2. Mac 側（AgentPets、第 2 期）

### 2.1 コア（`AgentPetsCore`、純粋関数）

- `DisplayState.subtitle: String` を追加する。`Aggregator` が作り、`sameView` の比較に含める。
  - hook セッション: `<detail> · <project|source>`。detail が空なら `<project|source>`。
  - manual: 送られた文そのもの（`message` と同じ）。状態が idle でも文があれば送る（`Aggregator` が manual を先に判定するのと同じ順）。
  - hook セッションの idle: 空。
  - `MessageText.sanitize` を通す。
- `StackChanRecord.encode(_ display: DisplayState, celebrateSeq: UInt8, maxLength: Int) -> Data?`
  - §1.2 の形式で組み立てる。実際の上限は `min(maxLength, 259)`。`maxLength < 4` なら nil。
  - 文の切り詰めは §1.2 のとおり。`…` を付けても収まらないほど小さいときは、文を空にする。

### 2.2 アプリ

| 部品 | 役割 |
|---|---|
| `FanOutSink: DisplaySink` | 複数の sink に同じ `DisplayState` を配る。`HubStore` は変えない |
| `StackChanSink: DisplaySink` | `celebrate` のたびに跳ねる番号を 1 増やし（255 の次は 0）、最新の `DisplayState` と番号を `RecordTransport` に渡す |
| `protocol RecordTransport` | `func send(display: DisplayState, celebrateSeq: UInt8)`。テストでは偽物に差し替える |
| `StackChanLink: RecordTransport`（MainActor、`queue: nil`） | CoreBluetooth central。scan → connect → discovery → write without response。最新の 1 件だけ保持し、§1.4 の契機（発見の直後・変化時・5 秒ごと）で送る。送る直前に `maximumWriteValueLength(for: .withoutResponse)` を読んで `StackChanRecord.encode` する。`canSendWriteWithoutResponse` が false なら `peripheralIsReady(toSendWriteWithoutResponse:)` まで待つ。切断時と `NSWorkspace.didWakeNotification` では §1.1 の手順（retrieve と scan の並行）をやり直す（`.poweredOn` のときのみ）。identifier は UserDefaults に保存 |
| メニュー | 「StackChan に送る」のオン／オフ（既定オフ、UserDefaults に保存）と接続状態の 1 行（未使用 / Bluetooth オフ / 許可されていません / 探しています / 接続中） |

- `FanOutSink` と `StackChanSink` はアプリ起動時に常設し、トグルに関係なく最新の `DisplayState` と跳ねる番号を持ち続ける。
  `HubStore` は同じ見た目を出し直さないので、トグル時に作ると状態が変わるまで送る値が無くなるため。
- `CBCentralManager` だけは「StackChan に送る」をオンにしたときに初めて作る。StackChan を使わない人に許可ダイアログを出さないため。
- オフにしたら、保留中・接続中の peripheral を `cancelPeripheralConnection` し、スキャンを止め、keep-alive を止める。
- connect・scan・retrieve は `state == .poweredOn` のときだけ行う。`centralManagerDidUpdateState` で `.poweredOn` になるたびに
  §1.1 の retrieve と scan をやり直す（Bluetooth の電源を切ると接続は切れ、`CBPeripheral` は無効になるため）。
- `.unauthorized` / `.poweredOff` はメニューに表示するだけで、ペット表示は止めない。
- ビルド設定（Debug・Release）: `ENABLE_RESOURCE_ACCESS_BLUETOOTH = YES`、`INFOPLIST_KEY_NSBluetoothAlwaysUsageDescription`。
  pbxproj は手で編集せず、Xcode の Signing & Capabilities / Build Settings で設定する（ユーザーの手作業）。
- delegate の隔離: アプリは `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`。`queue: nil`（メインキュー配送）で isolated conformance が実行時チェックを通るかは未検証。
  通らない場合は delegate メソッドを `nonisolated` にして `MainActor.assumeIsolated` で移る。

### 2.3 テスト

- コア: レコードの各バイト、切り詰め（ちょうど収まる、マルチバイト、絵文字、結合文字、`…` が入らない極小）、`maxLength < 4`、
  `maxLength = 512` で 120 文字の日本語（全長が 259 以下、L が実長と一致）、`subtitle` の各パターン（manual の idle を含む）。
- `StackChanSink`: 偽 transport で、celebrate ごとに番号が 1 増える、celebrate 無しでは増えない、255 → 0。
- `FanOutSink`: 全 sink に同じ値が届く。
- `StackChanLink`: 自動テストしない。実機で確認し記録する（接続、切断復帰、スリープ復帰、許可ダイアログ、実 MTU）。

## 3. StackChan ファームウェア（新規 repo、第 3 期）

### 3.1 repo と土台

- 場所: `~/work/tools/stackchan-pet`（git）。
- PoC（`~/agent-work/uwb-stackchan-poc`）から写すもの。写した commit / jj change と元パスを `docs/provenance.md` に記録する:
  - toolchain の固定: arduino-cli 1.1.1（project-local）、esp32 core 3.3.11、FQBN `esp32:esp32:m5stack_cores3:PSRAM=enabled,FlashSize=16M,PartitionScheme=custom`、M5Unified 0.2.25、M5GFX 0.2.32
  - `partitions.csv`（工場 NVS を readonly で保護）と `patches/arduino-nvs-label.patch`、`scripts/patch-arduino-core.py`
  - `vendor/StackChan-BSP`（PoC 改変版、上流 commit `8d4d6fc3b7a6be379c6317c45a02a30bff8c492e`、MIT。LICENSE を同梱）。
    写した後に、ON にできる経路を削る: `begin()`、`servo_init`、`Motion` と `utils/motion`、FTServo 系、
    `setServoPowerEnabled` / `setServoPowerEnabledChecked`、`io_expander_init(bool)`。代わりに ON を表現できない
    `forceServoPowerOff()` と、読み戻し用の `readServoPowerConfig()` だけを置く（§3.4）。削った内容を provenance に記録する
  - `scripts/build-firmware.sh` 相当
- Qorvo SDK など PoC の非公開・非関連コードは写さない。サーボ駆動・UWB・追従のコードも写さない。
- 顔のジオメトリは M5Stack 工場 FW のソース由来（MIT）。その commit と、各ファイルの SPDX ヘッダを provenance に記録する。

### 3.2 構成

```text
stackchan-pet/
├── firmware/
│   ├── core/                     ハードウェア非依存の C++17 ヘッダ（ホストでテスト）
│   │   ├── state_record.hpp      §1.2 の解析と検証（UTF-8 検証を含む）
│   │   └── pet_display_model.hpp 受理レコード・時刻 → 表示モデル（顔・状態語・文・跳ねる・未接続）
│   └── StackChanPet/
│       ├── StackChanPet.ino
│       ├── PetPeripheral.{h,cpp} 同梱 BLE（NimBLE バックエンド）で service/characteristic を公開
│       ├── FaceRenderer.{h,cpp}  M5GFX で顔・状態語・文を描く
│       └── SafeBoard.{h,cpp}     起動時と 1 秒ごとの安全確認（§3.4）
├── tests/cpp/                    core のホストテスト（依存なし、PoC と同じ c++ -std=c++17 -Wall -Wextra -Werror）
├── scripts/                      build-firmware.sh / check-core.sh / check-elf-safety.sh / check-vectors.sh / patch-arduino-core.py
├── vendor/StackChan-BSP/
├── partitions.csv, patches/
└── docs/provenance.md, docs/hardware-results.md
```

- 表示モデルは純粋関数 `PetDisplayModel::update(record or none, now_ms) -> DisplayModel` とし、watchdog・跳ねる判定・初回受理を含める。
  BLE の `onWrite` は NimBLE の host task で走るので、コールバック内ではデータをコピーして「最新 1 件だけの mailbox」に置くだけにする。
  mailbox は排他付きで、接続の世代番号を持つ。切断イベントも同じ mailbox に世代番号付きで置き、メインループが順に取り出して表示モデルに渡す。
  描画はメインループだけで行う。
- watchdog の経過は `uint32_t` の `now - last` で比べる（`millis()` の 49 日での一周に耐えるため）。
  接続したまま 15 秒で未接続になった後に届いたレコードは「接続後の初回」と同じ扱いにする（番号を覚えるだけで跳ねない）。
- 顔の描画は PoC の顔ジオメトリ（M5Stack 工場 FW 由来、MIT。出所を provenance に記録）を基にする。
  状態ごとの表情: idle=穏やか、working=まばたき多め・目線が動く、waiting=眉を上げ「?」、success=笑顔、error=困り顔、未接続=ニュートラル。
  success の笑顔は、最後の動き（状態か文の変化、または跳ねる）から 30 秒たつと穏やかな顔に戻す。keep-alive は動きに数えない。状態の語は「完了」のまま（2026-10-11 追加）。
  跳ねるは画面上で顔を 1 回上下させる（首は動かさない）。
- 画面: 普段は顔だけを全画面（320×240）に描く。画面をタップすると状態語と文の欄を開き、顔は上 170 px に寄せる。もう一度タップするか 10 秒たつと閉じる（M5Stack の StackChan 工場 FW のステータスバーに倣った。2026-10-11 追加）。サーボ電源の異常画面と基板の警告は、欄の開閉に関わらず常に出す。
- 文字: 状態語は大きめのフォント、文は `fonts::efontJA_10`（PoC で使用実績、約 220KB）。収まらない文はコードポイントの境界で末尾を切る。
- UTF-8 の検証は厳格にする: overlong、サロゲート（U+D800〜DFFF）、U+10FFFF 超、途中で切れた列は不正としてレコードごと捨てる。
- スプライト表示は第 3 期の範囲外。`FaceRenderer` を差し替えられる境界（表示モデルを受け取る interface）だけ用意する。

### 3.3 BLE

- 同梱 BLE ライブラリ。esp32 core 3.3.11 の ESP32-S3 向け sdkconfig では NimBLE バックエンドで、
  `CONFIG_BT_NIMBLE_MAX_CONNECTIONS=3`（PoC の調査で sdkconfig を読んで確認。実機での同時接続は未検証、§5）。
- 単一接続。接続中は advertising を止め、切断時だけ再開する（PoC と同じ `advertiseOnDisconnect(true)`）。
  統合デモで iPhone と Mac を同時につなぐときは、接続ごとの初回扱い・跳ねる番号・未接続判定を再設計する（範囲外）。
- characteristic のプロパティは write without response（`PROPERTY_WRITE_NR`）。
- 跳ねる番号は 1 バイトなので、切断中に合図がちょうど 256 回あると一致して喜ばない。実害が小さいので許容する。

### 3.4 安全

主張の範囲: このファームウェアは ESP32 からサーボ電源を ON にする経路を持たず、起動後に OFF を読み戻しで確かめる。
電源投入から OFF を書くまでの間（最短 200 ms〜最長約 1.4 秒）の VM 状態は保証しない。直前のファームウェアが VM を ON のまま
リセットされた場合、PY32 は ESP32 と別 MCU なので ON が残りうる（推定。§5）。

- 起動手順（`SafeBoard`）:
  1. `M5.begin()`。PY32 の起動を 200 ms 間隔・最大 1.2 秒待つ。
  2. **何も書く前に** PY32 の GPIO 設定（出力値・方向・プルアップ／ダウン、レジスタ 0x03〜0x0C の pin0 に関わるもの）を読み、
     シリアルと画面に出す（電源投入直後の状態の記録になる）。
  3. 書く順序は「出力値 0 → プルアップ off・プルダウン on → 方向を出力」。出力にする前に値を 0 にして、一瞬 ON になる窓を作らない
     （PoC の `beginSafeBoard` は方向を出力にしてから値を 0 にしている。`M5StackChan.cpp:73-75`）。
  4. 書いた後に読み戻し、出力値 0・方向が出力であることを確かめる。合否は書き込み ACK ではなく読み戻しで決める。
     読み戻しには失敗を区別できる `bool readRegister(reg, buf, len)`（M5Unified `I2C_Class`）で 0x03〜0x0C をまとめて読み、
     `{valid, mode, out, pu, pd}` で返す。`valid == false` は fault。`readRegister8` / `getWriteValue` は使わない
     （戻り値が `uint8_t` だけで I2C 失敗を知らせず、失敗が「出力値 0 ＝ OFF」と区別できないため）。
     同じ理由で、BSP の read-modify-write（`bitOn` / `bitOff`）を OFF の書き込みに使わず、読み取りに成功した値から書く値を作る。
  5. 以後 1 秒ごとに読み戻しを繰り返し、値が変わっていたら（PY32 のリセット等）OFF を書き直し、fault の記録を残す。
- 合否が取れないときは fault 表示（顔の代わりに「SERVO OFF 未確認」）。BLE の表示更新は続けるが fault 表示を優先する。
  INA226 の初期化失敗（PoC の `beginSafeBoard` では同じ false になる）は、これと区別して別の注意表示にする。
- サーボの UART（TX6/RX7）には触れない。
- 構造的な保証: vendor の BSP から ON にできる関数を削り（§3.1）、ビルド後に ELF を `nm -C` で検査する。
  `M5StackChan_Class::begin`、`servo_init`、`SCSCL`、`Motion`、`setServoPowerEnabled` のシンボルが 1 つでもあれば失敗。
  加えて、PY32 の GPIO 出力レジスタ（0x05/0x06）へ書くコードが `forceServoPowerOff` 以外に無いことを、
  `scripts/check-core.sh` で vendor を含めて grep する（`bitOn(`、`digitalWrite(`、0x05/0x06 や `REG_GPIO_O` を引数にした `writeRegister`）。

### 3.5 ビルドと書き込み

- ビルド: `scripts/build-firmware.sh`（PoC と同じ arduino-cli・FQBN）。
- 書き込みは、機種・シリアルポート・復旧手段・ユーザーの準備を確認してから行う（PoC の AGENTS.md と同じ規則）。
  - 機種: K151。ポート: 書き込みの直前に `ls /dev/cu.usbmodem*` とユーザー照合。
  - ユーザーの準備: 今入っているファームウェアで首が動作状態（arm）でないこと、首が正面にあることを確認してもらう。
  - 配置の照合（実機）: `esptool read_flash 0x8000 0xC00` で実機のパーティション表を読み、ビルドの `partitions.bin` と SHA-256 を照合する。
    一致しなければ中止する（工場 FW の配置では app0 が 0x20000 で、0x10000 への app 書き込みは工場 app を壊す）。
    `check-flash-layout.py` はローカル成果物だけを見るので、これの代わりにはならない。
  - 書き込み方: app だけを `0x10000` へ（`esptool 4.12.0`、PoC と同じ）。
  - 復旧手段（主）: 書き込み前に、実機の現在の app 領域を `read_flash` で保存し SHA-256 を記録する。戻すときはそれを `0x10000` へ書く
    （PoC の app 書き込みは実績が多い）。
  - 復旧手段（副、未試験）: 工場の全体イメージ `write_flash 0x0 k151-fw-1.5.1-full.bin`（PoC の `.cache/backups/`、SHA-256 照合済み）。
    復元の書き込み試験はしていないことを、書き込み前にユーザーへ伝える。
- 実機結果は `docs/hardware-results.md` に、日時・commit・手順・観察を記録する。ホストテストやビルド成功を実機確認の代わりにしない。

### 3.6 テスト

- ホスト（core）: 受理・拒否の各条件（全長、版、状態、L 不一致、不正 UTF-8 の各種、境界の L=0 と 255）、
  跳ねる（初回受理は跳ねない、番号変化で 1 回、同番号の keep-alive で跳ねない、success 以外では跳ねない、255→0、15 秒失効後の再受理は初回扱い）、
  watchdog（14.9 秒は接続扱い、15 秒で未接続、拒否レコードで延長しない、`millis()` の一周をまたぐ）、切断で即未接続、mailbox の世代番号で古い切断が新しい接続を消さない。
- テストベクタ: 正は AgentPets 側 `Packages/AgentPetsCore/Tests/AgentPetsCoreTests/Fixtures/stackchan/state-record-v1.txt`
  （1 行 1 ケース: 入力の hex、受理/拒否、期待値）。ファームウェア repo は `tests/vectors/` に写し、
  `scripts/check-vectors.sh <AgentPets のパス>` で両者のバイト一致を検査する（パス必須。無ければ失敗）。
- 安全: ELF の `nm -C` 検査と、出力レジスタへの書き込みの grep 検査（§3.4）。
  `readServoPowerConfig` の結果判定は core の純粋関数にしてホストでテストする。fault になるのは、valid=false、out の pin0 が 1、
  mode の pin0 が出力でない、pin0 のプルが「pull-up off・pull-down on」でない、のいずれか（§3.4 の書き順と一致させる）。
- 実機（`hardware-results.md`）: 書く前に読んだ PY32 の GPIO 設定、OFF の読み戻し、首が動かないこと、
  Mac との接続・状態変化の反映時間（1 秒以内）、跳ねる、15 秒で未接続、切断・再接続、電源再投入。

## 4. 実装の順番

1. Mac コア（`subtitle`、`StackChanRecord`）とテスト
2. ファームウェア core（`state_record`、`pet_display_model`）とホストテスト。1 と同じテストベクタ（バイト列）を共有する
3. ファームウェアのスケッチ（SafeBoard → BLE → 描画）。ビルドまで
4. Mac アプリ（`FanOutSink`、`StackChanSink`、`StackChanLink`、メニュー、ビルド設定）
5. 実機（すべてユーザー確認後）: 最初に `SafeBoard` だけのプローブ（BLE・描画なし。GPIO 設定を読んで記録し、その後 §3.4 の順で OFF を書いて読み戻す）
   を書き込んで電源投入直後の状態を記録 →
   app 領域の保存 → 本ファームウェアの書き込み → 結合確認

## 5. 未検証事項

| 事項 | 影響 | 確かめ方 |
|---|---|---|
| macOS の実際の `maximumWriteValueLength(.withoutResponse)` | 文の長さ | 実機で記録 |
| LSUIElement アプリでの Bluetooth 許可ダイアログの出方 | 初回体験 | 実機 |
| スリープ復帰時の CoreBluetooth の挙動 | 再接続の作り | 実機 |
| MainActor 既定モジュールでの delegate isolated conformance の実行時チェック | delegate の書き方 | ビルドと実機 |
| 同時接続（統合デモ） | 統合 | 範囲外。統合時に設計 |
| `efontJA_10` に `·` `…` のグリフがあるか、無いグリフ（絵文字等）がどう描かれるか | 文の表示 | 実機で描画確認。欠ける場合は Mac 側の区切り文字を変える |
| 電源投入直後・リセット直後の PY32 の GPIO 設定（VM EN） | 安全の主張の範囲 | PoC に記録は無い。§4 の 5 の「読むだけ」プローブで記録する。電圧の実測はしない |
| ESP32 のリセットで PY32 の出力が保持されるか | 安全の主張の範囲 | 同上のプローブで、直前に PoC FW が動いていた状態からの読み取りを記録 |
| PY32 が入力モードの間に書いた出力値を保持するか | §3.4 の書き順 | 保持しなくても直後の読み戻しで検出される。プローブで記録 |
| 工場 FW への全体復元 | 副の復旧手段 | 本 spec では試験しない。書き込み前にユーザーへ未試験を伝える |

## 6. 範囲外

- 首の動作（§1.5 の前提条件つき）
- スプライト表示
- 複数の StackChan、複数の Mac
- UWB PoC との統合
