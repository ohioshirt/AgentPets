# StackChan BLE Firmware Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新規 repo `~/work/tools/stackchan-pet` に、AgentPets から BLE で届く表示レコード（版 1）を受けて StackChan K151 の画面に顔・状態の語・短い文を出すファームウェアを作る。首を動かす経路は持たず、起動時と 1 秒ごとにサーボ電源 OFF を読み戻しで確かめる。

**Architecture:** ハードウェア非依存の判定（レコード解析、表示モデル、mailbox、サーボ電源の読み戻し判定、顔の姿勢、文の折り返し）は `firmware/core/` のヘッダだけの C++17 にしてホストでテストする。スケッチ `firmware/StackChanPet/` は `SafeBoard`（安全確認）、`PetPeripheral`（同梱 BLE / NimBLE）、`FaceRenderer`（M5GFX 描画）を core に配線するだけにする。BSP は PoC の改変版を写してから、サーボ電源を ON にできる経路を削り、OFF だけを表現する `forceServoPowerOff()` と読み取り API を足す。構造上の保証はビルド後の ELF 検査（`nm -C`）と、出力レジスタへの書き込みの grep 検査で取る。

**Tech Stack:** Arduino CLI 1.1.1（project-local）、esp32 core 3.3.11、M5Unified 0.2.25、M5GFX 0.2.32、同梱 BLE ライブラリ（NimBLE バックエンド）、ホストテストは `c++ -std=c++17 -Wall -Wextra -Werror`、書き込みは esptool 4.12.0（PoC の venv を写したもの）、git。

**Spec:** `~/work/tools/AgentPets/docs/superpowers/specs/2026-10-10-stackchan-ble-design.md`（commit 3470945）の §3（ファームウェア）と §1.3〜1.5（受信規則・生存確認・安全と認証）。Mac 側（§2）は別計画。各タスクの実装者は spec の該当節も読むこと。

## Global Constraints

- 場所: `~/work/tools/stackchan-pet`（git）。PoC `~/agent-work/uwb-stackchan-poc`（jj、非 colocated）は読むだけ。PoC で jj / git の書き込みをしない。jj は `--ignore-working-copy` を付けて実行し、PoC の working copy の snapshot も取らない。
- Service UUID `B405CCEA-139A-4248-9CDE-5BAB2613D855`、State characteristic UUID `24EE255E-42EC-4702-AF9C-C8EF325929AC`。プロパティは write without response のみ（`PROPERTY_WRITE_NR`、read・notify なし）。デバイス名 `StackChanPet`。Service UUID を advertise する。
- レコード: byte0 版 `1`、byte1 状態 0 idle / 1 working / 2 waiting / 3 success / 4 error、byte2 跳ねる番号 0〜255、byte3 文のバイト長 L（全長−4）、byte4〜 文（UTF-8）。全長 259 以下。
- 捨てるレコード: 全長 4 未満、版が 1 以外、状態が範囲外、L が残りバイト数と一致しない、文が UTF-8 として不正（overlong、U+D800〜DFFF、U+10FFFF 超、途中で切れた列）。捨てたときは表示を変えず watchdog も延長しない。
- 跳ねる: 状態が success で、跳ねる番号が直前に受理したレコードと違うときだけ。接続後（および 15 秒失効後）に最初に受理したレコードは番号を覚えるだけで跳ねない。同じ内容のレコードは watchdog を延長するだけで描画をやり直さない。
- watchdog 15 秒（`uint32_t` の `now - last` で比べ、`millis()` の一周に耐える）。切断を検知したら即ニュートラルな顔と「未接続」。切断後は advertising を再開（`advertiseOnDisconnect(true)`）。単一接続。ペアリングは要求しない。
- `onWrite` は NimBLE の host task で走る。コールバック内ではコピーして mailbox に置くだけ。描画はメインループだけ。
- 文字: 状態語は大きめ、文は `fonts::efontJA_10`。収まらない文はコードポイントの境界で末尾を切る。
- toolchain: arduino-cli 1.1.1（project-local `.cache/bin/arduino-cli`）、esp32 core 3.3.11、FQBN `esp32:esp32:m5stack_cores3:PSRAM=enabled,FlashSize=16M,PartitionScheme=custom`、M5Unified 0.2.25、M5GFX 0.2.32、StackChan-BSP 上流 commit `8d4d6fc3b7a6be379c6317c45a02a30bff8c492e`（MIT、LICENSE 同梱）、esptool 4.12.0。
- サーボ電源: PY32 IO expander（I2C `0x6F`、100 kHz、`m5::In_I2C`）の pin 0 が VM EN。レジスタ 0x03/0x04 方向（1=出力）、0x05/0x06 出力値、0x07/0x08 入力、0x09/0x0A プルアップ、0x0B/0x0C プルダウン（BSP `PY32IOExpander.cpp` の定義。Task 2 で写す前に原本と照合する）。OFF の書き順は「出力値 0 → プルアップ off・プルダウン on → 方向を出力」。合否は書き込み ACK ではなく読み戻しで決める。`readRegister8` / `getWriteValue` / `bitOn` / `bitOff` / `digitalWrite` を使わない。
- ESP32 からサーボ電源を ON にする経路を持たない。サーボの UART（TX6/RX7）に触れない。PoC のサーボ駆動・UWB・追従・Qorvo のコードを写さない。
- 書き込み・消去は、機種（K151）・シリアルポート（ユーザー照合）・復旧手段・ユーザーの準備（現 FW が arm でない、首が正面）を確かめてから、ユーザーの明示の了承を得て行う。自動で書き込まない。app だけを `0x10000` へ。merged.bin・`erase_flash`・`write_flash 0x0` は使わない（工場全体イメージによる復元を除く。それも未試験と伝えた上でユーザーが選んだときだけ）。
- ホストテストやビルド成功を実機確認の代わりにしない。実機結果は `docs/hardware-results.md` に、日時・commit・手順・観察・生ログの末尾で残す。
- 各ゲート（テスト・ビルド・検査）は、その場で実行したコマンドと生出力の末尾（10 行程度）を報告に添える。数値は出力から写す。
- macOS に `timeout` は無い。スクリプトで使わない。テストは依存の欠落を黙って飛ばさない。実装を写し取っただけのテスト（自分自身との比較）を書かない。
- git の staging はパスを明示する（`git add <path>`）。`git add -A` / `git add .` は使わない。commit 前に `git status --porcelain` で無関係な変更が無いことを見る。commit メッセージの末尾には、実際に作業したモデルの Co-Authored-By trailer を付ける（モデル名をこの計画から写さない）。
- 以下のコマンドは repo ルート `~/work/tools/stackchan-pet` で実行する前提で書いてある。Bash ツールで実行するときは最上位で `cd` せず、`(cd ~/work/tools/stackchan-pet && CMD)` か `git -C` を使う。

## Review Focus

spec がはっきり書いていないが、実機や実運用で最初に踏みそうな入力。各行のテストは担当タスクに入れてある。

1. **古い切断が新しい接続を消す**: Mac が切断→即再接続し、メインループが取り出す前に「旧接続の切断」と「新接続のレコード」が mailbox に並ぶ → 切断を先に、レコードを後に渡さないと、新しい接続が未接続表示のまま 15 秒固まる（Task 5 `testMailboxOrdersOldDisconnectBeforeNewRecord`、`testStaleDisconnectDoesNotClearNewConnection`）。
2. **`millis()` の一周**: 約 49.7 日連続稼働で `millis()` が 0 に戻る → `now - last` を符号なしで比べないと、未接続にならない／即未接続になる（Task 5 `testWatchdogAcrossMillisWrap`、Task 7 の跳ね動作も一周をまたいで検査）。
3. **259 バイトを超える write**: ATT は最大 512 バイトまで届きうる（同梱 BLE の書き込み処理は `BLE_ATT_ATTR_MAX_LEN` まで受ける）→ mailbox で 259 バイトに切ると「正しいレコード」に化けうる。260 バイトで止めて L 不一致で捨てる（Task 5 `testMailboxKeepsOverlongWriteRejectable`、Task 3 `testLengthBoundaries`）。
4. **I2C 読み取り失敗が OFF に見える**: `readRegister8` は失敗時に 0 を返す → 「出力値 0 ＝ OFF」と区別できない。失敗した読み取りは常に fault（Task 6 `testFailedReadIsNeverOff`）。PY32 がまとめ読みでアドレスを進めない場合も OFF に見えうるので、単独読みとの一致を条件に足す（Task 6 `testCombinedOffNeedsAgreement`、実機は Task 10 で確認）。
5. **長い無通信の直後のレコード**: メインループが描画などで遅れ、tick を挟まずに 20 秒ぶりのレコードを受ける → watchdog を先に評価しないと「初回」扱いにならず、再接続のたびに跳ねる（Task 5 `testLateRecordAfterSilenceIsFirstWithoutTick`）。

---

## File Structure

| パス | 責務 |
|---|---|
| `.gitignore` | `.cache/`（toolchain の写し・ビルド成果物・実機の読み出し）を除外 |
| `docs/provenance.md` | PoC から写したもの（元パス・PoC の jj revision・SHA-256）、BSP から削ったもの、顔ジオメトリの出所 |
| `docs/hardware-results.md` | 実機結果（Task 10・11） |
| `licenses/m5stack-StackChan-firmware-LICENSE.txt` | 顔ジオメトリの出所（M5Stack 工場 FW、MIT）のライセンス本文 |
| `firmware/dependencies.lock.json` | 版の固定（PoC から写し、パスだけ直す） |
| `firmware/StackChanPet/partitions.csv` | 工場 NVS を readonly で保護する配置（PoC と同一。arduino-cli の custom scheme はスケッチ直下を読む） |
| `patches/arduino-nvs-label.patch` | esp32 core の NVS ラベル修正（記録用。適用は `patch-arduino-core.py`） |
| `scripts/patch-arduino-core.py` | project-local core にだけガード付きでパッチを当てる（PoC と同一） |
| `scripts/check-flash-layout.py` / `tests/python/test_flash_layout.py` | 生成物の配置検査とそのテスト（PoC と同一） |
| `scripts/build-firmware.sh` | ビルド（`--probe` で SafeBoard だけのプローブ）、配置検査と ELF 検査まで |
| `scripts/check-core.sh` | ホストのゲート（core テスト・ベクタ・grep 検査・配置検査のテスト） |
| `scripts/check-servo-writes.sh` / `scripts/test-safety-checks.sh` | 出力レジスタへの書き込みの grep 検査と、その反例テスト |
| `scripts/check-elf-safety.sh` | ELF の `nm -C` 検査 |
| `scripts/check-vectors.sh` | AgentPets のテストベクタとのバイト一致 |
| `scripts/capture-serial.py` | シリアルを読むだけの記録（送信なし） |
| `vendor/StackChan-BSP/` | PoC 改変版 BSP の写しから ON 経路を削ったもの |
| `vendor/StackChan-BSP/src/drivers/PY32ServoPower/PY32Registers.hpp` | PY32 のアドレス・クロック・レジスタ表 |
| `vendor/StackChan-BSP/src/ServoPowerOff.cpp` | 出力レジスタへ書く唯一の関数 `forceServoPowerOff` |
| `firmware/core/utf8.hpp` | 厳格な UTF-8 検証 |
| `firmware/core/state_record.hpp` | §1.2 の解析と §1.3 の拒否 |
| `firmware/core/pet_display_model.hpp` | 受理レコード・切断・時刻 → 表示モデル（watchdog・跳ねる・初回・世代番号） |
| `firmware/core/pet_mailbox.hpp` | BLE task → メインループの受け渡し（最新 1 件、世代番号つき） |
| `firmware/core/servo_power_check.hpp` | PY32 の読み戻しの解釈と合否 |
| `firmware/core/face_pose.hpp` | 表示モデル・時刻 → 顔の種類・まばたき・目線・跳ねる高さ |
| `firmware/core/text_layout.hpp` | コードポイント境界での折り返しと切り詰め |
| `firmware/core/library.properties` | core を Arduino ライブラリとして渡す |
| `firmware/StackChanPet/StackChanPet.ino` | 配線とメインループ |
| `firmware/StackChanPet/SafeBoard.{h,cpp}` | 起動手順と 1 秒ごとの再確認（§3.4） |
| `firmware/StackChanPet/PetPeripheral.{h,cpp}` | GATT と mailbox（§1.1、§3.3） |
| `firmware/StackChanPet/FaceRenderer.{h,cpp}` | 顔・状態語・文・fault 画面（差し替え境界 `PetRenderer`） |
| `tests/cpp/*.cpp` | core のホストテスト |
| `tests/vectors/state-record-v1.txt` | AgentPets 側の正本の写し |

---

### Task 1: repo の骨組みと toolchain の写し

**前提:** `~/work/tools/stackchan-pet` が存在しないこと（存在すれば中身を確かめてユーザーに報告し、止まる）。

**Files:**
- Create: `.gitignore`, `docs/provenance.md`, `licenses/m5stack-StackChan-firmware-LICENSE.txt`
- Create（PoC から写す）: `firmware/StackChanPet/partitions.csv`, `patches/arduino-nvs-label.patch`, `scripts/patch-arduino-core.py`, `scripts/check-flash-layout.py`, `tests/python/test_flash_layout.py`, `firmware/dependencies.lock.json`
- Create: `scripts/build-firmware.sh`, `scripts/check-core.sh`
- 非管理（`.cache/`）: `.cache/bin/arduino-cli`, `.cache/arduino/{data,user}`, `.cache/esptool-legacy`

**Interfaces:**
- Produces: `scripts/build-firmware.sh [--clean] [--probe]`（Task 8 で初めて実行する。`scripts/check-elf-safety.sh` は Task 8 で作る）
- Produces: `scripts/check-core.sh`（以後のタスクが行を足す）

- [ ] **Step 1: PoC の revision と写す元を記録する**

```bash
POC=~/agent-work/uwb-stackchan-poc
jj --ignore-working-copy log -R "$POC" -r @ --no-graph -T 'change_id ++ " " ++ commit_id ++ " " ++ description.first_line() ++ "\n"'
jj --ignore-working-copy log -R "$POC" -r @- --no-graph -T 'change_id ++ " " ++ commit_id ++ " " ++ description.first_line() ++ "\n"'
jj --ignore-working-copy diff -R "$POC" -r @ --stat -- firmware/vendor firmware/StackChanTracker/partitions.csv firmware/patches firmware/dependencies.lock.json scripts tests/python
```

出力をそのまま控える（Step 6 で provenance に書く）。`--ignore-working-copy` なので、`@` は最後に取られた snapshot で、その後の未 snapshot の変更を含まないことがある。出所は Step 3 で記録する各ファイルの SHA-256 で確定させ、revision は参考として書く。

- [ ] **Step 2: git repo と .gitignore**

```bash
mkdir -p ~/work/tools/stackchan-pet
git -C ~/work/tools/stackchan-pet init
```

`.gitignore`:

```gitignore
.cache/
.DS_Store
```

- [ ] **Step 3: 固定された土台を写す**

```bash
POC=~/agent-work/uwb-stackchan-poc
mkdir -p firmware/StackChanPet patches scripts tests/python licenses docs
cp "$POC/firmware/StackChanTracker/partitions.csv" firmware/StackChanPet/partitions.csv
cp "$POC/firmware/patches/arduino-nvs-label.patch" patches/arduino-nvs-label.patch
cp "$POC/scripts/patch-arduino-core.py" scripts/patch-arduino-core.py
cp "$POC/scripts/check-flash-layout.py" scripts/check-flash-layout.py
cp "$POC/tests/python/test_flash_layout.py" tests/python/test_flash_layout.py
cp "$POC/firmware/dependencies.lock.json" firmware/dependencies.lock.json
cp "$POC/.cache/StackChan-factory/firmware/LICENSE" licenses/m5stack-StackChan-firmware-LICENSE.txt
shasum -a 256 "$POC/firmware/StackChanTracker/partitions.csv" "$POC/firmware/patches/arduino-nvs-label.patch" \
  "$POC/scripts/patch-arduino-core.py" "$POC/scripts/check-flash-layout.py" "$POC/tests/python/test_flash_layout.py" \
  "$POC/firmware/dependencies.lock.json" "$POC/.cache/StackChan-factory/firmware/LICENSE"
git -C "$POC/.cache/StackChan-factory" rev-parse HEAD
```

Expected: 最後の行が `1b5765599fba8aaad1811d9a79358ccc7051f5f3`（工場 FW のローカル clone。違えば provenance に実際の値を書き、ユーザーに報告する）。

`firmware/dependencies.lock.json` の `partitionTable.source` を `firmware/StackChanTracker/partitions.csv` から `firmware/StackChanPet/partitions.csv` に直す（Edit で 1 箇所。ほかは変えない）。

- [ ] **Step 4: toolchain を写す（APFS clone、ネットワーク不要）**

PoC で使ってきた、固定版・パッチ済みの toolchain を写す。新しい依存のダウンロードはしない（R-SEC-01: 新規の取得が無いので監査対象は増えない）。`cp -c` は clonefile なので容量はほぼ増えない。

```bash
POC=~/agent-work/uwb-stackchan-poc
mkdir -p .cache/bin .cache/arduino
cp -c "$POC/.cache/bin/arduino-cli" .cache/bin/arduino-cli
cp -Rc "$POC/.cache/arduino/data" .cache/arduino/data
cp -Rc "$POC/.cache/arduino/user" .cache/arduino/user
cp -Rc "$POC/.cache/esptool-legacy" .cache/esptool-legacy
shasum -a 256 .cache/bin/arduino-cli
.cache/bin/arduino-cli version
grep -h '^version=' .cache/arduino/user/libraries/M5Unified/library.properties .cache/arduino/user/libraries/M5GFX/library.properties
ls .cache/arduino/data/packages/esp32/hardware/esp32
.cache/esptool-legacy/bin/python -I -c 'import esptool, serial; print(esptool.__version__, serial.VERSION, esptool.__file__)'
python3 scripts/patch-arduino-core.py
```

Expected:
- arduino-cli の SHA-256 が `5e318cfd179a7b97bd25ae2cba6f73717cd83ee0f8f7e5beea822ec79f80315a`、`Version: 1.1.1`
- `version=0.2.25`（M5Unified）、`version=0.2.32`（M5GFX）、core のディレクトリは `3.3.11` だけ
- esptool `4.12.0`、pyserial `3.5`、`esptool.__file__` が `~/work/tools/stackchan-pet/.cache/esptool-legacy/...` を指す（PoC を指していたら venv の写しが効いていない。止まって報告）
- `patch-arduino-core.py` は `already has the guarded patch` と patched sha256 `de3acbc773ea417c15ea6ef53e61df56d5b226ac65f149974dc3ba713776bc6e`

`.cache/arduino-cli.yaml` は写さない（PoC の絶対パスが入っている）。`build-firmware.sh` が初回に作る。

- [ ] **Step 5: ビルドスクリプトと check-core.sh**

`scripts/build-firmware.sh`（PoC の `scripts/build-firmware.sh` を基に、スケッチ・ライブラリのパス、`--probe`、ELF 検査を変えたもの）:

```bash
#!/usr/bin/env bash
# Build StackChanPet with the pinned project-local toolchain (copied from the
# UWB PoC, see docs/provenance.md). Never uploads.
#   build-firmware.sh [--clean] [--probe]
#   --probe: SafeBoard-only probe (-DPET_SAFEBOARD_PROBE=1), separate build dir.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CLEAN=0
PROBE=0
for arg in "$@"; do
  case "$arg" in
    --clean) CLEAN=1 ;;
    --probe) PROBE=1 ;;
    *)
      echo "usage: $0 [--clean] [--probe]" >&2
      exit 2
      ;;
  esac
done

CLI="$ROOT_DIR/.cache/bin/arduino-cli"
CLI_CONFIG="$ROOT_DIR/.cache/arduino-cli.yaml"
ARDUINO_DATA_DIR="$ROOT_DIR/.cache/arduino/data"
ARDUINO_USER_DIR="$ROOT_DIR/.cache/arduino/user"
CORE_DIR="$ARDUINO_DATA_DIR/packages/esp32/hardware/esp32/3.3.11"
SKETCH_DIR="$ROOT_DIR/firmware/StackChanPet"
FQBN="esp32:esp32:m5stack_cores3:PSRAM=enabled,FlashSize=16M,PartitionScheme=custom"
if [[ $PROBE -eq 1 ]]; then
  BUILD_DIR="$ROOT_DIR/.cache/firmware-build-probe"
  LOG_SUFFIX="-probe"
else
  BUILD_DIR="$ROOT_DIR/.cache/firmware-build"
  LOG_SUFFIX=""
fi

run_captured() {
  local log_file="$1"
  shift
  if "$@" >"$log_file" 2>&1; then
    tail -n 14 "$log_file"
  else
    local status=$?
    tail -n 24 "$log_file" >&2
    return "$status"
  fi
}

if [[ ! -x "$CLI" ]]; then
  echo "missing project-local Arduino CLI: $CLI" >&2
  exit 1
fi
if [[ ! -d "$CORE_DIR" ]]; then
  echo "missing pinned Arduino ESP32 core 3.3.11: $CORE_DIR" >&2
  exit 1
fi
if [[ ! -f "$SKETCH_DIR/partitions.csv" ]]; then
  echo "missing custom partition CSV: $SKETCH_DIR/partitions.csv" >&2
  exit 1
fi

mkdir -p "$ROOT_DIR/.cache" "$BUILD_DIR"
if [[ ! -f "$CLI_CONFIG" ]]; then
  cat >"$CLI_CONFIG" <<EOF
board_manager:
  additional_urls:
    - https://espressif.github.io/arduino-esp32/package_esp32_index.json
directories:
  data: '$ARDUINO_DATA_DIR'
  downloads: '$ROOT_DIR/.cache/arduino/downloads'
  user: '$ARDUINO_USER_DIR'
EOF
fi

PATCH_LOG="$ROOT_DIR/.cache/patch-arduino-core.log"
run_captured "$PATCH_LOG" python3 "$ROOT_DIR/scripts/patch-arduino-core.py"

BUILD_LOG="$ROOT_DIR/.cache/build-firmware$LOG_SUFFIX.log"
BUILD_ARGS=(
  compile
  --config-file "$CLI_CONFIG"
  --fqbn "$FQBN"
  --build-path "$BUILD_DIR"
  --library "$ROOT_DIR/vendor/StackChan-BSP"
  --library "$ROOT_DIR/firmware/core"
)
if [[ $PROBE -eq 1 ]]; then
  BUILD_ARGS+=(--build-property "compiler.cpp.extra_flags=-DPET_SAFEBOARD_PROBE=1")
fi
if [[ $CLEAN -eq 1 ]]; then
  BUILD_ARGS+=(--clean)
fi
BUILD_ARGS+=("$SKETCH_DIR")
run_captured "$BUILD_LOG" "$CLI" "${BUILD_ARGS[@]}"

PROJECT_PREFIX="$BUILD_DIR/StackChanPet.ino"
PARTITION_LOG="$ROOT_DIR/.cache/check-flash-layout$LOG_SUFFIX.log"
run_captured "$PARTITION_LOG" python3 "$ROOT_DIR/scripts/check-flash-layout.py" \
  --bootloader "$PROJECT_PREFIX.bootloader.bin" \
  --partition-table "$PROJECT_PREFIX.partitions.bin" \
  --boot-app0 "$BUILD_DIR/boot_app0.bin" \
  --app "$PROJECT_PREFIX.bin"

ELF_LOG="$ROOT_DIR/.cache/check-elf-safety$LOG_SUFFIX.log"
run_captured "$ELF_LOG" "$ROOT_DIR/scripts/check-elf-safety.sh" "$PROJECT_PREFIX.elf"
```

`scripts/check-core.sh`（この時点では配置検査のテストだけ。以後のタスクが行を足す）:

```bash
#!/usr/bin/env bash
# Host checks: core tests, shared wire vectors, servo-power write greps.
# No hardware, no Arduino build.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
mkdir -p .cache/host

run_test() {
  local name="$1"
  shift
  c++ -std=c++17 -Wall -Wextra -Werror -I firmware/core \
    "tests/cpp/$name.cpp" -o ".cache/host/$name"
  ".cache/host/$name" "$@"
}

python3 -m unittest discover -s tests/python
```

```bash
chmod +x scripts/build-firmware.sh scripts/check-core.sh scripts/patch-arduino-core.py scripts/check-flash-layout.py
scripts/check-core.sh 2>&1 | tail -5
```

Expected: unittest の末尾が `OK`。

- [ ] **Step 6: provenance を書く**

`docs/provenance.md`（`<...>` は Step 1・3・4 の出力から写す。推測で埋めない）:

```markdown
# Provenance

## UWB PoC から写したもの

PoC: `~/agent-work/uwb-stackchan-poc`（jj、非 colocated）
- `@`: <change_id> <commit_id>（Step 1 の出力）
- `@-`: <change_id> <commit_id>
- 写したパスの `jj --ignore-working-copy diff -r @ --stat`: <出力。空なら「変更なし」>（`@` は最後の snapshot。出所の確定は下の SHA-256）

| 写した先 | 元パス | SHA-256（元） | 変更 |
|---|---|---|---|
| `firmware/StackChanPet/partitions.csv` | `firmware/StackChanTracker/partitions.csv` | <sha> | なし |
| `patches/arduino-nvs-label.patch` | `firmware/patches/arduino-nvs-label.patch` | <sha> | なし |
| `scripts/patch-arduino-core.py` | `scripts/patch-arduino-core.py` | <sha> | なし |
| `scripts/check-flash-layout.py` | `scripts/check-flash-layout.py` | <sha> | なし |
| `tests/python/test_flash_layout.py` | `tests/python/test_flash_layout.py` | <sha> | なし |
| `firmware/dependencies.lock.json` | `firmware/dependencies.lock.json` | <sha> | `partitionTable.source` のパスのみ |
| `scripts/build-firmware.sh` | `scripts/build-firmware.sh` | <sha> | スケッチ名・ライブラリのパス・`--probe`・ELF 検査 |
| `vendor/StackChan-BSP/` | `firmware/vendor/StackChan-BSP/` | Task 2 | Task 2 の節 |

toolchain（`.cache/`、非管理）: `.cache/bin/arduino-cli`（SHA-256 <sha>、1.1.1）、`.cache/arduino/data`（esp32 core 3.3.11、NVS パッチ適用済み）、`.cache/arduino/user`（M5Unified 0.2.25、M5GFX 0.2.32 ほか lock のとおり）、`.cache/esptool-legacy`（esptool 4.12.0、pyserial 3.5）。PoC の `.cache/` から `cp -c` / `cp -Rc` で写した。新規ダウンロードはしていない。

写していないもの: Qorvo SDK と関連コード、サーボ駆動・UWB・追従・校正のコード、iOS アプリ、PoC の `firmware/core/`。

## 顔ジオメトリ

`firmware/StackChanPet/FaceRenderer.cpp` の `drawFace` は、PoC `firmware/StackChanTracker/Firmware.cpp` の `drawFace`（上記 `@` の版）を基にしている。PoC の `drawFace` は M5Stack の工場 FW（https://github.com/m5stack/StackChan.git、ローカル clone の revision <Step 3 の rev-parse>）の `firmware/main/stackchan/avatar/skins/default/{default.cpp,eyes.cpp,mouth.cpp}` のジオメトリに由来する。3 ファイルとも SPDX ヘッダは `SPDX-FileCopyrightText: 2026 M5Stack Technology CO LTD` / `SPDX-License-Identifier: MIT`。ライセンス本文は `licenses/m5stack-StackChan-firmware-LICENSE.txt`（元: 工場 FW clone の `firmware/LICENSE`、SHA-256 <sha>）。

## このリポジトリ自体のライセンス

未定（ユーザーが決める）。vendor と licenses/ の MIT 表示は保持する。
```

- [ ] **Step 7: Commit**

```bash
git add .gitignore docs/provenance.md licenses/m5stack-StackChan-firmware-LICENSE.txt firmware/StackChanPet/partitions.csv patches/arduino-nvs-label.patch scripts/patch-arduino-core.py scripts/check-flash-layout.py tests/python/test_flash_layout.py firmware/dependencies.lock.json scripts/build-firmware.sh scripts/check-core.sh
git status --porcelain
git commit -m "Scaffold stackchan-pet with the toolchain pins copied from the UWB PoC"
```

Expected: `git status --porcelain` に `.cache/` が出ない（ignore されている）。

---

### Task 2: BSP を写し、サーボ電源を ON にできる経路を削る

**Files:**
- Create（PoC から写す）: `vendor/StackChan-BSP/`（まず無改変で commit）
- Delete: `vendor/StackChan-BSP/src/drivers/FTServo_Arduino/`, `src/drivers/PY32IOExpander/`, `src/utils/motion/`, `src/utils/settings/`, `src/utils/uitk/`
- Replace: `vendor/StackChan-BSP/src/M5StackChan.h`, `vendor/StackChan-BSP/src/M5StackChan.cpp`
- Create: `vendor/StackChan-BSP/src/drivers/PY32ServoPower/PY32Registers.hpp`, `vendor/StackChan-BSP/src/ServoPowerOff.cpp`
- Create: `scripts/check-servo-writes.sh`, `scripts/test-safety-checks.sh`
- Modify: `scripts/check-core.sh`, `docs/provenance.md`

**Interfaces:**
- Produces（`namespace m5`）:
  - `struct ServoPowerRaw { bool valid; std::uint8_t reg[10]; }`（0x03〜0x0C のまとめ読み。`valid == false` ならバイトに意味は無い）
  - `bool M5StackChan_Class::waitForIoExpander()`（読むだけ。200 ms 間隔、約 1.2 秒で諦める。元の `io_expander_init` と同じ間隔）
  - `ServoPowerRaw M5StackChan_Class::readServoPowerConfig()`（`I2C_Device::readRegister` の bool で成否を返す）
  - `bool M5StackChan_Class::readIoExpanderByte(std::uint8_t reg, std::uint8_t* value)`（読むだけ。まとめ読みの照合用）
  - `bool M5StackChan_Class::forceServoPowerOff(const ServoPowerRaw& current)`（pin 0 を出力値 0 → プルアップ off → プルダウン on → 出力、の順に書く。他のビットは `current` の値を保つ。出力値の書き込みが NACK なら方向を書かずに false）
  - `bool M5StackChan_Class::beginPowerMonitor()`（INA226 `0x41`。元 `ina226_init` に成否を足したもの）
  - `namespace m5::py32` の定数（`kAddress = 0x6F`、`kClockHz = 100000`、`REG_*`、`kIndex*`、`kVmEnBit = 0x01`）
- 削除（ELF 検査が Task 8 から見張る）: `begin()`、`beginSafeBoard()`、`update()`、`TouchSensor` メンバ、`Motion` メンバ、`setServoPowerEnabled`、`setServoPowerEnabledChecked`、`setRgbColor` / `refreshRgb` / `showRgbColor`、`io_expander_init`、`servo_init`、`ScsServo`、`SCSCL` ほか FTServo 系、`PY32IOExpander_Class`

**spec からの補足（Deviations に記録する）:** spec §3.1 の削除対象に加えて、`utils/settings`（サーボ校正だけが使い、NVS の `servo` 名前空間に書く）、`utils/uitk`（motion とサーボだけが使う）、RGB の関数（PY32 への書き込み）、`update()` と `TouchSensor` メンバ（`TouchSensor.update()` は `begin()` 前に呼ぶと null を参照する）も削る。`PY32IOExpander_Class` は `digitalWrite` を純粋仮想として実装しなければならず ON を表現できるので、ドライバごと外し、レジスタ表だけを `PY32Registers.hpp` に残す。`readServoPowerConfig()` は spec の `{valid, mode, out, pu, pd}` ではなく生のバイトを返し、解釈は core（Task 6、ホストでテスト）で行う（vendor を core に依存させないため）。

- [ ] **Step 1: レジスタ表とアドレスを原本で確かめる**

```bash
POC=~/agent-work/uwb-stackchan-poc
grep -n 'DEFAULT_ADDRESS\|uint32_t freq = ' "$POC/firmware/vendor/StackChan-BSP/src/drivers/PY32IOExpander/PY32IOExpander.hpp"
grep -n 'REG_VERSION\|REG_GPIO_M_\|REG_GPIO_O_\|REG_GPIO_I_\|REG_GPIO_PU_\|REG_GPIO_PD_' "$POC/firmware/vendor/StackChan-BSP/src/drivers/PY32IOExpander/PY32IOExpander.cpp" | head -12
grep -n 'VM EN\|setDirection(0\|digitalWrite(0' "$POC/firmware/vendor/StackChan-BSP/src/M5StackChan.cpp"
grep -rln '0x6F\|0x6f' "$POC/.cache/arduino/user/libraries/M5Unified/src"
grep -n '0x6F\|0x6f' "$POC/.cache/arduino/user/libraries/M5Unified/src/utility/imu/BMI270_Class.hpp"
```

Expected（計画作成時に原本で確認済み。食い違えば止まって報告）:
- `DEFAULT_ADDRESS = 0x6F`、既定 `freq = 100000`、`i2c = &m5::In_I2C`
- `REG_VERSION = 0x02`、`REG_GPIO_M_L/H = 0x03/0x04`、`O 0x05/0x06`、`I 0x07/0x08`、`PU 0x09/0x0A`、`PD 0x0B/0x0C`
- `M5StackChan.cpp` で pin 0 が `// VM EN`、`digitalWrite(0, enabled)`
- M5Unified 本体で `0x6F` を含むのは `utility/imu/BMI270_Class.hpp`（`SELF_TEST_MEMS_ADDR = 0x6F`、BMI270 内部のレジスタ番号）と `utility/imu/BMI270_config.inl`（BMI270 の設定データのバイト列）の 2 ファイルだけ。どちらも I2C アドレスとしての使用ではない（M5.begin() が PY32 に触れない）。ほかのファイルが出たら止まって報告

- [ ] **Step 2: 無改変で写して commit する（削った差分を git に残すため）**

```bash
POC=~/agent-work/uwb-stackchan-poc
mkdir -p vendor
cp -R "$POC/firmware/vendor/StackChan-BSP" vendor/StackChan-BSP
(cd "$POC/firmware/vendor" && find StackChan-BSP -type f | sort | xargs shasum -a 256) > .cache/bsp-copy-sha256.txt
(cd vendor && find StackChan-BSP -type f | sort | xargs shasum -a 256) | diff - .cache/bsp-copy-sha256.txt && echo BSP_COPY_IDENTICAL
git add vendor/StackChan-BSP
git status --porcelain
git commit -m "Vendor the PoC copy of StackChan-BSP unchanged"
```

Expected: `BSP_COPY_IDENTICAL`。

- [ ] **Step 3: 失敗する検査を書く（反例が通ってしまうことを確認）**

`scripts/check-servo-writes.sh`:

```bash
#!/usr/bin/env bash
# Spec 3.4: nothing in this repository may write the PY32 GPIO output
# register or use read-modify-write / pin-level writes, except the masked OFF
# sequence in vendor/StackChan-BSP/src/ServoPowerOff.cpp.
#   check-servo-writes.sh [repo root]
set -euo pipefail

ROOT_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ALLOWED="vendor/StackChan-BSP/src/ServoPowerOff.cpp"
READER="vendor/StackChan-BSP/src/M5StackChan.cpp"
REGISTERS="vendor/StackChan-BSP/src/drivers/PY32ServoPower/PY32Registers.hpp"
cd "$ROOT_DIR"

fail() {
  echo "check-servo-writes: $*" >&2
  exit 1
}

[[ -d firmware && -d vendor ]] || fail "run from the repository root"
for file in "$ALLOWED" "$READER" "$REGISTERS"; do
  [[ -f "$file" ]] || fail "missing $file"
done

search() {
  grep -rnE --include='*.c' --include='*.cpp' --include='*.h' \
    --include='*.hpp' --include='*.ino' --include='*.inl' "$1" firmware vendor || true
}

# 1. Pin-level writes, read-modify-write helpers, output-register writes.
hits="$(search 'bitOn[[:space:]]*\(|bitOff[[:space:]]*\(|digitalWrite[[:space:]]*\(|writeRegister8?[[:space:]]*\([^;]*(0x0?[56]([^0-9A-Fa-fx]|$)|REG_GPIO_O)' |
  grep -v "^$ALLOWED:" || true)"
if [[ -n "$hits" ]]; then
  printf '%s\n' "$hits" >&2
  fail "forbidden GPIO output / read-modify-write call outside $ALLOWED"
fi

# 2. Raw bus access that bypasses I2C_Device (and so these rules).
hits="$(search '(In_I2C|Ex_I2C|Wire[0-9]*)[[:space:]]*(\.|->)[[:space:]]*(write|start|restart|beginTransmission|bitOn|bitOff)|m5gfx::i2c::|i2c_master_')"
if [[ -n "$hits" ]]; then
  printf '%s\n' "$hits" >&2
  fail "raw I2C access; go through m5::I2C_Device"
fi

# 3. The PY32 address may appear only in the reader, the OFF writer and the
#    register header.
hits="$(search '0x6[Ff]([^0-9A-Fa-f]|$)|py32::kAddress' |
  grep -v -e "^$ALLOWED:" -e "^$READER:" -e "^$REGISTERS:" || true)"
if [[ -n "$hits" ]]; then
  printf '%s\n' "$hits" >&2
  fail "PY32 address used outside $READER / $ALLOWED"
fi

# 4. The reader reads only.
if grep -nE 'write[A-Za-z0-9]*[[:space:]]*\(|bitOn|bitOff' "$READER" >&2; then
  fail "$READER must not write"
fi

# 5. The OFF writer: four single-register writes, no burst, no high byte,
#    output value first and masked, direction last.
if grep -nE 'bitOn|bitOff|digitalWrite|REG_GPIO_O_H|0x06|writeRegister[[:space:]]*\(|writeRegister8Array' "$ALLOWED" >&2; then
  fail "$ALLOWED uses a forbidden helper, a burst write or the high output byte"
fi
writes="$(grep -cE 'writeRegister8[[:space:]]*\(' "$ALLOWED" || true)"
[[ "$writes" == "4" ]] || fail "expected 4 register writes in $ALLOWED, found $writes"
line_of() {
  local found
  found="$(grep -nE "writeRegister8\(py32::$1, $2\)" "$ALLOWED" | cut -d: -f1)"
  [[ "$(printf '%s\n' "$found" | grep -c .)" == "1" ]] || fail "expected one write of $2 to $1 in $ALLOWED"
  printf '%s' "$found"
}
out_line="$(line_of REG_GPIO_O_L outLow)"
pu_line="$(line_of REG_GPIO_PU_L pullUpLow)"
pd_line="$(line_of REG_GPIO_PD_L pullDownLow)"
mode_line="$(line_of REG_GPIO_M_L modeLow)"
(( out_line < pu_line && pu_line < pd_line && pd_line < mode_line )) ||
  fail "write order must be output value, pull-up, pull-down, direction"
masked="$(grep -cE 'outLow[[:space:]]*=[[:space:]]*static_cast<std::uint8_t>\(current\.reg\[py32::kIndexOutputLow\] & ~py32::kVmEnBit\);' "$ALLOWED" || true)"
[[ "$masked" == "1" ]] || fail "outLow must be the read value with the VM EN bit cleared"
echo "check-servo-writes: ok"
```

`scripts/test-safety-checks.sh`:

```bash
#!/usr/bin/env bash
# Counterexamples for scripts/check-servo-writes.sh: each injected write must
# make it fail, and an untouched copy of the real tree must pass.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/stackchan-safety.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fresh_tree() {
  rm -rf "$WORK/tree"
  mkdir -p "$WORK/tree"
  cp -R "$ROOT_DIR/firmware" "$ROOT_DIR/vendor" "$WORK/tree/"
}

expect() {
  local want="$1" label="$2"
  if "$ROOT_DIR/scripts/check-servo-writes.sh" "$WORK/tree" >"$WORK/out" 2>&1; then
    got=pass
  else
    got=fail
  fi
  if [[ "$got" != "$want" ]]; then
    echo "test-safety-checks: $label: expected $want, got $got" >&2
    cat "$WORK/out" >&2
    exit 1
  fi
  echo "test-safety-checks: $label: $got (expected): $(tail -n 1 "$WORK/out")"
}

fresh_tree
expect pass "real tree"

fresh_tree
echo 'void f(m5::I2C_Device& d) { d.writeRegister8(0x05, 1); }' >"$WORK/tree/firmware/StackChanPet/Injected.cpp"
expect fail "output register write by number in the sketch"

fresh_tree
echo 'void f(const m5::I2C_Device& d) { d.writeRegister8(m5::py32::REG_GPIO_O_L, 1); }' >"$WORK/tree/vendor/StackChan-BSP/src/Injected.cpp"
expect fail "output register write by name in vendor"

fresh_tree
mkdir -p "$WORK/tree/firmware/core"
echo 'void f(const m5::I2C_Device& d) { d.bitOn(0x03, 1); }' >"$WORK/tree/firmware/core/injected.hpp"
expect fail "read-modify-write helper in core"

fresh_tree
echo 'void f(m5::IOExpander_Base& e) { e.digitalWrite(0, true); }' >"$WORK/tree/vendor/StackChan-BSP/src/Injected.cpp"
expect fail "pin-level write"

fresh_tree
sed -i '' 's/ & ~py32::kVmEnBit);/);/' "$WORK/tree/vendor/StackChan-BSP/src/ServoPowerOff.cpp"
expect fail "unmasked output value in ServoPowerOff.cpp"

fresh_tree
echo 'static void g(const m5::I2C_Device& d) { d.writeRegister8(py32::REG_GPIO_O_L, 0); }' >>"$WORK/tree/vendor/StackChan-BSP/src/ServoPowerOff.cpp"
expect fail "second output write in ServoPowerOff.cpp"

fresh_tree
echo 'void f(const m5::I2C_Device& d, const std::uint8_t* b) { d.writeRegister(m5::py32::REG_GPIO_M_L, b, 10); }' >>"$WORK/tree/vendor/StackChan-BSP/src/ServoPowerOff.cpp"
expect fail "burst write over the GPIO block"

fresh_tree
echo 'void g() { m5::In_I2C.writeRegister8(0x6F, 5, 1, 100000); }' >"$WORK/tree/firmware/StackChanPet/Injected.cpp"
expect fail "raw bus write with the PY32 address"

fresh_tree
echo 'static const m5::I2C_Device other(0x6F, 100000);' >"$WORK/tree/firmware/StackChanPet/Injected.cpp"
expect fail "PY32 address outside the BSP reader and writer"

fresh_tree
echo 'bool h(const m5::I2C_Device& d) { return d.writeRegister8(0x09, 0); }' >>"$WORK/tree/vendor/StackChan-BSP/src/M5StackChan.cpp"
expect fail "write in the read-only reader"

fresh_tree
python3 -I - "$WORK/tree/vendor/StackChan-BSP/src/ServoPowerOff.cpp" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
mode = "    const bool modeOk = dev.writeRegister8(py32::REG_GPIO_M_L, modeLow);\n"
assert mode in text
text = text.replace(mode, "")
text = text.replace("    // 1. output value 0 first", mode + "    // 1. output value 0 first")
open(path, "w").write(text)
PY
expect fail "direction written before the output value"
```

```bash
chmod +x scripts/check-servo-writes.sh scripts/test-safety-checks.sh
scripts/check-servo-writes.sh 2>&1 | tail -5; echo "exit=${PIPESTATUS[0]}"
```

Expected: 写したままの BSP では失敗する（`missing vendor/StackChan-BSP/src/ServoPowerOff.cpp`）。`ServoPowerOff.cpp` だけ先に置いても、`PY32IOExpander.cpp` の `bitOn(` / `digitalWrite(` が列挙されて失敗する。

検査の規則（計画レビューで強めたもの）: (1) `bitOn` / `bitOff` / `digitalWrite`、0x05・0x06・`REG_GPIO_O` を引数にした `writeRegister` は `ServoPowerOff.cpp` 以外で禁止。(2) `In_I2C` / `Ex_I2C` / `Wire` への直接の write・start、`m5gfx::i2c::`、`i2c_master_` は全面禁止（`I2C_Device` を通さない書き込みを塞ぐ）。(3) PY32 のアドレス（`0x6F` / `py32::kAddress`）は `M5StackChan.cpp`・`ServoPowerOff.cpp`・`PY32Registers.hpp` 以外に出てはならない。(4) `M5StackChan.cpp` は書き込みを含まない。(5) `ServoPowerOff.cpp` は 1 レジスタずつの書き込みちょうど 4 つ、まとめ書き・高位バイト無し、行の順が出力値 → プルアップ → プルダウン → 方向、出力値はマスク済みの読み取り値。grep なので、複数行に割った呼び出しや変数経由のレジスタ番号は (1) では拾えない。(3)・(4)・(5) で PY32 に書ける場所を `ServoPowerOff.cpp` に閉じ込めて補う。

- [ ] **Step 4: ON 経路を削る**

```bash
git rm -r -q vendor/StackChan-BSP/src/drivers/FTServo_Arduino vendor/StackChan-BSP/src/drivers/PY32IOExpander vendor/StackChan-BSP/src/utils/motion vendor/StackChan-BSP/src/utils/settings vendor/StackChan-BSP/src/utils/uitk
mkdir -p vendor/StackChan-BSP/src/drivers/PY32ServoPower
```

`vendor/StackChan-BSP/src/drivers/PY32ServoPower/PY32Registers.hpp`:

```cpp
/*
 * SPDX-FileCopyrightText: 2026 M5Stack Technology CO LTD
 *
 * SPDX-License-Identifier: MIT
 *
 * Bus settings and the GPIO register map of the StackChan PY32 IO expander,
 * taken unchanged from the IO expander driver of StackChan-BSP (upstream
 * 8d4d6fc3b7a6be379c6317c45a02a30bff8c492e). That driver is not shipped
 * here; see docs/provenance.md for its path and hash.
 */
#pragma once

#include <cstddef>
#include <cstdint>

namespace m5 {
namespace py32 {

constexpr std::uint8_t kAddress = 0x6F;       // driver DEFAULT_ADDRESS
constexpr std::uint32_t kClockHz = 100000;    // driver default freq

constexpr std::uint8_t REG_VERSION = 0x02;
constexpr std::uint8_t REG_GPIO_M_L = 0x03;   // mode, 1 = output
constexpr std::uint8_t REG_GPIO_O_L = 0x05;   // output value
constexpr std::uint8_t REG_GPIO_PU_L = 0x09;  // pull-up enable
constexpr std::uint8_t REG_GPIO_PD_L = 0x0B;  // pull-down enable

// 0x03..0x0C: M_L M_H O_L O_H I_L I_H PU_L PU_H PD_L PD_H
constexpr std::size_t kGpioBlockLength = 10;
constexpr std::size_t kIndexModeLow = 0;
constexpr std::size_t kIndexOutputLow = 2;
constexpr std::size_t kIndexPullUpLow = 6;
constexpr std::size_t kIndexPullDownLow = 8;

// Servo power enable (VM EN) is PY32 pin 0 (M5StackChan.cpp "VM EN").
constexpr std::uint8_t kVmEnBit = 0x01;

}  // namespace py32
}  // namespace m5
```

`vendor/StackChan-BSP/src/M5StackChan.h`（全体を置き換える）:

```cpp
/*
 * SPDX-FileCopyrightText: 2026 M5Stack Technology CO LTD
 *
 * SPDX-License-Identifier: MIT
 *
 * Modified for stackchan-pet: every path that can turn servo power on or drive
 * the servos was removed. See docs/provenance.md for the removed code.
 */
#pragma once
#include "drivers/PY32ServoPower/PY32Registers.hpp"
#include <M5GFX.h>
#include <M5Unified.hpp>
#include <cstdint>
#include <memory>

namespace m5 {

// Raw PY32 GPIO block 0x03..0x0C. `valid` is false unless the I2C transfer
// completed; the bytes of a failed transfer mean nothing.
struct ServoPowerRaw {
    bool valid = false;
    std::uint8_t reg[py32::kGpioBlockLength] = {};
};

class M5StackChan_Class {
public:
    inline LGFX_Device& Display()
    {
        return M5.Display;
    }

    /**
     * @brief Wait for the PY32 IO expander to answer (200 ms steps, about
     * 1.2 s at most). Reads only.
     */
    bool waitForIoExpander();

    /**
     * @brief Read the GPIO block 0x03..0x0C in one transfer. Reads only.
     */
    ServoPowerRaw readServoPowerConfig();

    /**
     * @brief Read one PY32 register. Reads only. Used to cross-check the
     * block read.
     */
    bool readIoExpanderByte(std::uint8_t reg, std::uint8_t* value);

    /**
     * @brief Put VM EN (pin 0) into "output, value 0, pull-down" using the
     * other bits of `current`, a successful read. Writes in the order output
     * value -> pull-up off -> pull-down on -> direction output, and stops
     * before the direction write if the output-value write is not
     * acknowledged. There is no way to request power on.
     * @return true only if every write was acknowledged. The caller decides
     * by reading back, not by this value.
     */
    bool forceServoPowerOff(const ServoPowerRaw& current);

    /**
     * @brief Initialise the INA226 battery monitor (0x41).
     */
    bool beginPowerMonitor();

    float getBatteryVoltage();
    float getBatteryCurrent();
};

}  // namespace m5

extern m5::M5StackChan_Class M5StackChan;
```

`vendor/StackChan-BSP/src/M5StackChan.cpp`（全体を置き換える。INA226 部分は元のまま、PY32 の待ちは元と同じ 200 ms / 1200 ms）:

```cpp
/*
 * SPDX-FileCopyrightText: 2026 M5Stack Technology CO LTD
 *
 * SPDX-License-Identifier: MIT
 *
 * Modified for stackchan-pet: the board start-up, servo power and servo
 * code was removed (list in docs/provenance.md). This file only reads the
 * PY32; the PY32 wait loop keeps the original timing.
 */
#include "M5StackChan.h"
#include "utils/compat/make_unique.h"
#include "utility/power/INA226_Class.hpp"
#include <esp_log.h>

using namespace m5;

M5StackChan_Class M5StackChan;

static const char* TAG = "M5StackChan";
static std::unique_ptr<m5::INA226_Class> _ina226;

/* -------------------------------------------------------------------------- */
/*                                 IO Expander                                */
/* -------------------------------------------------------------------------- */
bool M5StackChan_Class::waitForIoExpander()
{
    const I2C_Device dev(py32::kAddress, py32::kClockHz, &In_I2C);

    // PY32 IO Expander may boot slowly, wait for it (same loop as the original
    // board start-up: 200 ms steps, give up after 1200 ms).
    uint32_t start_tick = millis();
    while (1) {
        delay(200);

        if (millis() - start_tick > 1200) {
            ESP_LOGE(TAG, "IO expander init timeout");
            return false;
        }

        std::uint8_t version = 0;
        if (dev.readRegister(py32::REG_VERSION, &version, 1) && version != 0x00 && version != 0xFF) {
            return true;
        }
    }
}

ServoPowerRaw M5StackChan_Class::readServoPowerConfig()
{
    const I2C_Device dev(py32::kAddress, py32::kClockHz, &In_I2C);
    ServoPowerRaw raw{};
    raw.valid = dev.readRegister(py32::REG_GPIO_M_L, raw.reg, sizeof(raw.reg));
    return raw;
}

bool M5StackChan_Class::readIoExpanderByte(std::uint8_t reg, std::uint8_t* value)
{
    if (value == nullptr) {
        return false;
    }
    const I2C_Device dev(py32::kAddress, py32::kClockHz, &In_I2C);
    return dev.readRegister(reg, value, 1);
}

/* -------------------------------------------------------------------------- */
/*                                   INA226                                   */
/* -------------------------------------------------------------------------- */
bool M5StackChan_Class::beginPowerMonitor()
{
    _ina226 = std::make_unique<m5::INA226_Class>(0x41);

    m5::INA226_Class::config_t config;
    config.shunt_res            = 0.01;
    config.max_expected_current = 8.19;
    _ina226->config(config);

    if (!_ina226->begin()) {
        ESP_LOGE(TAG, "INA226 init failed");
        _ina226.reset();
        return false;
    }
    return true;
}

float M5StackChan_Class::getBatteryVoltage()
{
    float result = 0.0f;
    if (_ina226) {
        result = _ina226->getBusVoltage();
    }
    return result;
}

float M5StackChan_Class::getBatteryCurrent()
{
    float result = 0.0f;
    if (_ina226) {
        result = _ina226->getShuntCurrent();
    }
    return result;
}
```

`vendor/StackChan-BSP/src/ServoPowerOff.cpp`:

```cpp
/*
 * SPDX-License-Identifier: MIT
 *
 * stackchan-pet addition to StackChan-BSP (not upstream code).
 * The only code in this repository that writes the PY32 GPIO output register;
 * scripts/check-servo-writes.sh enforces that. Pin 0 (VM EN) is only ever
 * written with constant OFF values; the other bits come from a successful
 * read so nothing else on the expander changes.
 */
#include "M5StackChan.h"

namespace m5 {

bool M5StackChan_Class::forceServoPowerOff(const ServoPowerRaw& current)
{
    if (!current.valid) {
        return false;
    }
    const I2C_Device dev(py32::kAddress, py32::kClockHz, &In_I2C);

    const std::uint8_t outLow = static_cast<std::uint8_t>(current.reg[py32::kIndexOutputLow] & ~py32::kVmEnBit);
    const std::uint8_t pullUpLow = static_cast<std::uint8_t>(current.reg[py32::kIndexPullUpLow] & ~py32::kVmEnBit);
    const std::uint8_t pullDownLow = static_cast<std::uint8_t>(current.reg[py32::kIndexPullDownLow] | py32::kVmEnBit);
    const std::uint8_t modeLow = static_cast<std::uint8_t>(current.reg[py32::kIndexModeLow] | py32::kVmEnBit);

    // 1. output value 0 first, so that switching to output never drives 1.
    if (!dev.writeRegister8(py32::REG_GPIO_O_L, outLow)) {
        return false;  // do not make the pin an output on an unknown latch
    }
    // 2. pull-up off, 3. pull-down on.
    const bool pullUpOk = dev.writeRegister8(py32::REG_GPIO_PU_L, pullUpLow);
    const bool pullDownOk = dev.writeRegister8(py32::REG_GPIO_PD_L, pullDownLow);
    // 4. direction output.
    const bool modeOk = dev.writeRegister8(py32::REG_GPIO_M_L, modeLow);
    return pullUpOk && pullDownOk && modeOk;
}

}  // namespace m5
```

削ったファイルを参照する include が残っていないことを確かめる:

```bash
grep -rnE 'FTServo|SCSCL|PY32IOExpander|utils/motion|utils/settings|uitk|smooth_ui_toolkit|setServoPowerEnabled|io_expander_init|servo_init' vendor/StackChan-BSP; echo "grep-exit=$?"
```

Expected: 何も出ず `grep-exit=1`。

- [ ] **Step 5: 検査が通ることと、反例が落ちることを確かめる**

`scripts/check-core.sh` の末尾に足す:

```bash
scripts/check-servo-writes.sh
scripts/test-safety-checks.sh
```

```bash
scripts/check-core.sh 2>&1 | tail -10; echo "exit=${PIPESTATUS[0]}"
```

Expected: `check-servo-writes: ok`、`test-safety-checks:` の 12 行（`real tree: pass`、残り 11 行は `fail (expected)`。各行の末尾に落ちた理由が出るので、反例の名前と理由が対応していることを目で確かめる）、`exit=0`。

- [ ] **Step 6: provenance に BSP の節を足す**

`docs/provenance.md` の表の `vendor/StackChan-BSP/` 行の「変更」を「下の節」に直し、次の節を足す:

```markdown
## vendor/StackChan-BSP

元: PoC `firmware/vendor/StackChan-BSP/`（PoC による改変版。上流 https://github.com/m5stack/StackChan-BSP commit `8d4d6fc3b7a6be379c6317c45a02a30bff8c492e`、version 1.1.0、MIT。`LICENSE` を同梱）。
無改変の写しは commit <Step 2 の hash>。写した直後に全ファイルの SHA-256 を元と照合した（Step 2 の `BSP_COPY_IDENTICAL`）。

削ったもの（commit <Step 7 の hash> の diff が正）:
- `src/drivers/FTServo_Arduino/`（サーボの UART 駆動。`SCSCL` ほか。同梱の LICENSE ごと）
- `src/drivers/PY32IOExpander/`（`digitalWrite` で VM EN を ON にできる。レジスタ表だけ `src/drivers/PY32ServoPower/PY32Registers.hpp` に残した）
- `src/utils/motion/`（`Motion` とサーボ抽象）
- `src/utils/settings/`（サーボ校正だけが使い、NVS に書く）
- `src/utils/uitk/`（motion とサーボだけが使う。Forairaaaaa の MIT。LICENSE ごと）
- `M5StackChan.{h,cpp}` から: `begin()`、`beginSafeBoard()`、`update()`、`TouchSensor` / `Motion` メンバ、`setServoPowerEnabled`、`setServoPowerEnabledChecked`、`setRgbColor`、`refreshRgb`、`showRgbColor`、`io_expander_init`、`servo_init`、`ServoConfig_t`、`ScsServo`、`_scs_bus`、`_io_expander`

足したもの: `waitForIoExpander()`、`readServoPowerConfig()`、`readIoExpanderByte()`、`forceServoPowerOff()`（`src/ServoPowerOff.cpp`、このリポジトリで新規）、`beginPowerMonitor()`（元 `ina226_init` に成否を足した）。

残したもの（未使用だが ON 経路ではない）: `src/utils/touch_sensor/`、`src/drivers/Si12T/`、`src/utils/compat/`、`src/StackChan-BSP.h`、`library.properties`、`library.json`、`LICENSE`。
```

- [ ] **Step 7: Commit**

```bash
git add vendor/StackChan-BSP scripts/check-servo-writes.sh scripts/test-safety-checks.sh scripts/check-core.sh docs/provenance.md
git status --porcelain
git commit -m "Strip every servo power-on and servo drive path from the vendored BSP"
```

commit 後に hash を provenance の `<Step 7 の hash>` に入れ、`git add docs/provenance.md && git commit -m "Record the BSP strip commit in provenance"` で残す。

---

### Task 3: レコードの解析（`utf8.hpp`、`state_record.hpp`）

**Files:**
- Create: `firmware/core/utf8.hpp`, `firmware/core/state_record.hpp`, `firmware/core/library.properties`
- Test: `tests/cpp/state_record_tests.cpp`
- Modify: `scripts/check-core.sh`

**Interfaces:**
- Produces（`namespace pet`）:
  - `std::size_t utf8SequenceLength(const std::uint8_t*, std::size_t available)`（不正なら 0）、`bool isValidUtf8(const std::uint8_t*, std::size_t)`
  - `enum class PetState : std::uint8_t { Idle = 0, Working = 1, Waiting = 2, Success = 3, Error = 4 }`
  - `enum class RecordError : std::uint8_t { None, Short, Version, Status, Length, Utf8 }`。判定順はこの並び（短い → 版 → 状態 → 長さ → UTF-8）で、最初に当たった理由を返す
  - `struct StateRecord { PetState state; std::uint8_t celebrateSeq; std::uint8_t textLength; std::uint8_t text[255]; }`
  - `ParseResult parseStateRecord(const std::uint8_t* data, std::size_t length)`、`const char* recordErrorName(RecordError)`（`short` / `version` / `status` / `length` / `utf8`。ベクタの理由名と同じ）
  - 定数 `kRecordVersion = 1`、`kRecordHeaderLength = 4`、`kTextCapacity = 255`、`kRecordMaxLength = 259`

- [ ] **Step 1: 失敗するテストを書く**

`tests/cpp/state_record_tests.cpp`（期待値は spec §1.2・§1.3・§3.2・§3.6 と Unicode の UTF-8 定義（RFC 3629 / Unicode Table 3-7）から）:

```cpp
// Host tests for firmware/core/state_record.hpp, from spec 2026-10-10
// sections 1.2, 1.3, 3.2 and 3.6. The shared byte vectors are checked by
// state_record_vector_tests.cpp.
#include "state_record.hpp"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

namespace {

int failures = 0;

#define CHECK(condition)                                                      \
  do {                                                                        \
    if (!(condition)) {                                                       \
      std::fprintf(stderr, "%s:%d: CHECK(%s) failed\n", __FILE__, __LINE__, \
                   #condition);                                              \
      ++failures;                                                             \
    }                                                                         \
  } while (false)

using Bytes = std::vector<std::uint8_t>;

pet::ParseResult parse(const Bytes& bytes) {
  return pet::parseStateRecord(bytes.empty() ? nullptr : bytes.data(),
                               bytes.size());
}

Bytes record(std::uint8_t version, std::uint8_t status, std::uint8_t seq,
             const Bytes& text) {
  Bytes bytes{version, status, seq, static_cast<std::uint8_t>(text.size())};
  bytes.insert(bytes.end(), text.begin(), text.end());
  return bytes;
}

void testHeaderRules() {
  CHECK(parse(Bytes{}).error == pet::RecordError::Short);
  CHECK(parse(Bytes{1, 0, 0}).error == pet::RecordError::Short);
  CHECK(parse(Bytes{1, 0, 0, 0}).error == pet::RecordError::None);
  CHECK(parse(Bytes{0, 0, 0, 0}).error == pet::RecordError::Version);
  CHECK(parse(Bytes{2, 0, 0, 0}).error == pet::RecordError::Version);
  CHECK(parse(Bytes{1, 4, 0, 0}).error == pet::RecordError::None);
  CHECK(parse(Bytes{1, 5, 0, 0}).error == pet::RecordError::Status);
  CHECK(parse(Bytes{1, 0xff, 0, 0}).error == pet::RecordError::Status);
  // L larger and smaller than the remaining bytes.
  CHECK(parse(Bytes{1, 0, 0, 1}).error == pet::RecordError::Length);
  CHECK(parse(Bytes{1, 0, 0, 0, 'a'}).error == pet::RecordError::Length);
  // Rule order: version is reported before status and length.
  CHECK(parse(Bytes{2, 9, 0, 7}).error == pet::RecordError::Version);
  CHECK(parse(Bytes{1, 9, 0, 7}).error == pet::RecordError::Status);
}

void testLengthBoundaries() {
  const auto empty = parse(record(1, 1, 7, Bytes{}));
  CHECK(empty.error == pet::RecordError::None);
  CHECK(empty.record.state == pet::PetState::Working);
  CHECK(empty.record.celebrateSeq == 7);
  CHECK(empty.record.textLength == 0);

  const Bytes full(255, 'x');
  const auto max = parse(record(1, 3, 255, full));
  CHECK(max.error == pet::RecordError::None);
  CHECK(max.record.textLength == 255);
  CHECK(max.record.text[0] == 'x' && max.record.text[254] == 'x');

  // 260 bytes can never satisfy L (one byte) and must be rejected.
  Bytes tooLong = record(1, 0, 0, full);
  tooLong.push_back('x');
  CHECK(tooLong.size() == 260);
  CHECK(parse(tooLong).error == pet::RecordError::Length);
}

void testUtf8() {
  // Accepted: ASCII, 2/3/4-byte forms at their edges.
  CHECK(parse(record(1, 0, 0, Bytes{0xc2, 0x80})).error == pet::RecordError::None);
  CHECK(parse(record(1, 0, 0, Bytes{0xe3, 0x81, 0x82})).error == pet::RecordError::None);  // あ
  CHECK(parse(record(1, 0, 0, Bytes{0xe2, 0x80, 0xa6})).error == pet::RecordError::None);  // …
  CHECK(parse(record(1, 0, 0, Bytes{0xed, 0x9f, 0xbf})).error == pet::RecordError::None);  // U+D7FF
  CHECK(parse(record(1, 0, 0, Bytes{0xee, 0x80, 0x80})).error == pet::RecordError::None);  // U+E000
  CHECK(parse(record(1, 0, 0, Bytes{0xf0, 0x9f, 0x98, 0x80})).error == pet::RecordError::None);  // emoji
  CHECK(parse(record(1, 0, 0, Bytes{0xf4, 0x8f, 0xbf, 0xbf})).error == pet::RecordError::None);  // U+10FFFF

  // Rejected: overlong forms.
  CHECK(parse(record(1, 0, 0, Bytes{0xc0, 0x80})).error == pet::RecordError::Utf8);
  CHECK(parse(record(1, 0, 0, Bytes{0xc1, 0xbf})).error == pet::RecordError::Utf8);
  CHECK(parse(record(1, 0, 0, Bytes{0xe0, 0x9f, 0xbf})).error == pet::RecordError::Utf8);
  CHECK(parse(record(1, 0, 0, Bytes{0xf0, 0x8f, 0xbf, 0xbf})).error == pet::RecordError::Utf8);
  // Rejected: surrogates U+D800 and U+DFFF.
  CHECK(parse(record(1, 0, 0, Bytes{0xed, 0xa0, 0x80})).error == pet::RecordError::Utf8);
  CHECK(parse(record(1, 0, 0, Bytes{0xed, 0xbf, 0xbf})).error == pet::RecordError::Utf8);
  // Rejected: above U+10FFFF and invalid lead bytes.
  CHECK(parse(record(1, 0, 0, Bytes{0xf4, 0x90, 0x80, 0x80})).error == pet::RecordError::Utf8);
  CHECK(parse(record(1, 0, 0, Bytes{0xf5, 0x80, 0x80, 0x80})).error == pet::RecordError::Utf8);
  CHECK(parse(record(1, 0, 0, Bytes{0xff})).error == pet::RecordError::Utf8);
  // Rejected: stray continuation and sequences cut by the end of the text.
  CHECK(parse(record(1, 0, 0, Bytes{0x80})).error == pet::RecordError::Utf8);
  CHECK(parse(record(1, 0, 0, Bytes{'a', 0xe3, 0x81})).error == pet::RecordError::Utf8);
  CHECK(parse(record(1, 0, 0, Bytes{0xf0, 0x9f, 0x98})).error == pet::RecordError::Utf8);
  // The length bounds the check: a sequence cut by `length` is malformed even
  // when the bytes after it would complete it.
  const std::uint8_t hiragana[] = {0xe3, 0x81, 0x82};
  CHECK(pet::isValidUtf8(hiragana, 3));
  CHECK(!pet::isValidUtf8(hiragana, 2));
  CHECK(!pet::isValidUtf8(hiragana, 1));
  // A bad continuation byte inside an otherwise complete length.
  CHECK(parse(record(1, 0, 0, Bytes{0xe3, 0x41, 0x82})).error == pet::RecordError::Utf8);
}

}  // namespace

int main() {
  testHeaderRules();
  testLengthBoundaries();
  testUtf8();
  if (failures != 0) {
    std::fprintf(stderr, "state_record_tests: %d failure(s)\n", failures);
    return 1;
  }
  std::puts("state_record_tests: ok");
  return 0;
}
```

`scripts/check-core.sh` の `python3 -m unittest` の行の前に足す:

```bash
run_test state_record_tests
```

```bash
scripts/check-core.sh 2>&1 | tail -5; echo "exit=${PIPESTATUS[0]}"
```

Expected: `fatal error: 'state_record.hpp' file not found`、`exit=1`。

- [ ] **Step 2: 実装する**

`firmware/core/utf8.hpp`:

```cpp
#pragma once

#include <cstddef>
#include <cstdint>

namespace pet {

// Length of the well-formed UTF-8 sequence starting at data[0] (RFC 3629,
// Unicode Table 3-7), or 0 when it is malformed: overlong forms, surrogates
// U+D800..U+DFFF, code points above U+10FFFF, stray continuation bytes and
// sequences cut off by the end of the buffer.
inline std::size_t utf8SequenceLength(const std::uint8_t* data,
                                      std::size_t available) {
  if (data == nullptr || available == 0) {
    return 0;
  }
  const std::uint8_t lead = data[0];
  if (lead < 0x80) {
    return 1;
  }
  std::size_t length = 0;
  std::uint8_t secondLow = 0x80;
  std::uint8_t secondHigh = 0xBF;
  if (lead >= 0xC2 && lead <= 0xDF) {
    length = 2;
  } else if (lead == 0xE0) {
    length = 3;
    secondLow = 0xA0;
  } else if ((lead >= 0xE1 && lead <= 0xEC) || lead == 0xEE || lead == 0xEF) {
    length = 3;
  } else if (lead == 0xED) {
    length = 3;
    secondHigh = 0x9F;
  } else if (lead == 0xF0) {
    length = 4;
    secondLow = 0x90;
  } else if (lead >= 0xF1 && lead <= 0xF3) {
    length = 4;
  } else if (lead == 0xF4) {
    length = 4;
    secondHigh = 0x8F;
  } else {
    return 0;
  }
  if (available < length) {
    return 0;
  }
  if (data[1] < secondLow || data[1] > secondHigh) {
    return 0;
  }
  for (std::size_t index = 2; index < length; ++index) {
    if (data[index] < 0x80 || data[index] > 0xBF) {
      return 0;
    }
  }
  return length;
}

inline bool isValidUtf8(const std::uint8_t* data, std::size_t length) {
  std::size_t offset = 0;
  while (offset < length) {
    const std::size_t step = utf8SequenceLength(data + offset, length - offset);
    if (step == 0) {
      return false;
    }
    offset += step;
  }
  return true;
}

}  // namespace pet
```

`firmware/core/state_record.hpp`:

```cpp
#pragma once

#include "utf8.hpp"

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace pet {

// Wire contract v1 (spec 2026-10-10-stackchan-ble-design.md section 1.2).
constexpr std::uint8_t kRecordVersion = 1;
constexpr std::size_t kRecordHeaderLength = 4;
constexpr std::size_t kTextCapacity = 255;
constexpr std::size_t kRecordMaxLength = kRecordHeaderLength + kTextCapacity;  // 259

enum class PetState : std::uint8_t {
  Idle = 0,
  Working = 1,
  Waiting = 2,
  Success = 3,
  Error = 4,
};

// Checked in this order; the first failing rule names the rejection.
enum class RecordError : std::uint8_t {
  None,
  Short,    // total length < 4
  Version,  // byte 0 != 1
  Status,   // byte 1 > 4
  Length,   // byte 3 != total length - 4
  Utf8,     // text is not well-formed UTF-8
};

struct StateRecord {
  PetState state = PetState::Idle;
  std::uint8_t celebrateSeq = 0;
  std::uint8_t textLength = 0;
  std::uint8_t text[kTextCapacity] = {};
};

inline bool sameText(const StateRecord& a, const StateRecord& b) {
  return a.textLength == b.textLength &&
         std::memcmp(a.text, b.text, a.textLength) == 0;
}

struct ParseResult {
  RecordError error = RecordError::Short;
  StateRecord record{};
};

inline ParseResult parseStateRecord(const std::uint8_t* data,
                                    std::size_t length) {
  ParseResult result{};
  if (data == nullptr || length < kRecordHeaderLength) {
    result.error = RecordError::Short;
    return result;
  }
  if (data[0] != kRecordVersion) {
    result.error = RecordError::Version;
    return result;
  }
  if (data[1] > static_cast<std::uint8_t>(PetState::Error)) {
    result.error = RecordError::Status;
    return result;
  }
  if (static_cast<std::size_t>(data[3]) != length - kRecordHeaderLength) {
    result.error = RecordError::Length;
    return result;
  }
  const std::uint8_t* text = data + kRecordHeaderLength;
  if (!isValidUtf8(text, data[3])) {
    result.error = RecordError::Utf8;
    return result;
  }
  result.error = RecordError::None;
  result.record.state = static_cast<PetState>(data[1]);
  result.record.celebrateSeq = data[2];
  result.record.textLength = data[3];
  std::memcpy(result.record.text, text, data[3]);
  return result;
}

inline const char* recordErrorName(RecordError error) {
  switch (error) {
    case RecordError::None:
      return "none";
    case RecordError::Short:
      return "short";
    case RecordError::Version:
      return "version";
    case RecordError::Status:
      return "status";
    case RecordError::Length:
      return "length";
    case RecordError::Utf8:
      return "utf8";
  }
  return "unknown";
}

}  // namespace pet
```

`firmware/core/library.properties`（`includes` は Task 7 までに作るヘッダを先に列挙しておく。Arduino のライブラリ探索は `includes` を必須としない）:

```text
name=StackChanPetCore
version=1.0.0
author=stackchan-pet contributors
maintainer=stackchan-pet contributors
sentence=Header-only wire, display and servo-power check core for StackChanPet
paragraph=Deterministic parsing and display state shared by the firmware and host tests.
category=Device Control
architectures=*
includes=state_record.hpp,pet_display_model.hpp,pet_mailbox.hpp,record_intake.hpp,servo_power_check.hpp,face_pose.hpp,text_layout.hpp,utf8.hpp
```

- [ ] **Step 3: 通ることを確かめる**

```bash
scripts/check-core.sh 2>&1 | tail -12; echo "exit=${PIPESTATUS[0]}"
```

Expected: `state_record_tests: ok`、`exit=0`。

- [ ] **Step 4: Commit**

```bash
git add firmware/core/utf8.hpp firmware/core/state_record.hpp firmware/core/library.properties tests/cpp/state_record_tests.cpp scripts/check-core.sh
git status --porcelain
git commit -m "Parse wire contract v1 records with strict UTF-8 validation"
```

- [ ] **Step 5: 判定が効いていることを確かめる（変異、commit の後）**

このステップは commit の後に行う（戻す先が commit 済みの内容になるように）。各行を 1 つずつ Edit で入れ、`scripts/check-core.sh` が失敗する（`exit=1`、表の右列のテストが FAIL 行に出る）ことを見てから、`git checkout -- <変えたファイル>` で戻す。全部終わったら `git status --porcelain` が空で、`scripts/check-core.sh` が `exit=0` であることを確かめる（生出力の末尾を残す）。変異を commit しない。

| 変異 | 落ちるべきテスト |
|---|---|
| `utf8.hpp` の `secondHigh = 0x9F;` を `0xBF` | サロゲート U+D800 / U+DFFF |
| `utf8.hpp` の `secondHigh = 0x8F;` を `0xBF` | U+10FFFF 超 |
| `utf8.hpp` の `lead >= 0xC2` を `lead >= 0xC0` | overlong `c0 80` |
| `utf8.hpp` の `if (available < length) {` を `if (false) {` | `isValidUtf8(hiragana, 2)` |
| `state_record.hpp` の状態の上限を `> 5` | `{1, 5, 0, 0}` |

計画作成時に同じ変異で全部が落ちることを確認済み（scratch での `c++` 実行）。

---

### Task 4: AgentPets と共有するテストベクタ

**前提:** AgentPets 側（Mac 計画）のベクタのタスクが commit 済みで、`~/work/tools/AgentPets/Packages/AgentPetsCore/Tests/AgentPetsCoreTests/Fixtures/stackchan/state-record-v1.txt` が存在すること。無ければこのタスクを保留して Task 5 へ進み、Task 11 の前に必ず戻る（Task 11 の前提）。ファイルを自分で作らない（正本は AgentPets 側）。

**Files:**
- Create: `tests/vectors/state-record-v1.txt`（正本の写し）
- Create: `scripts/check-vectors.sh`
- Test: `tests/cpp/state_record_vector_tests.cpp`
- Modify: `scripts/check-core.sh`

**Interfaces:**
- Consumes: ベクタの形式（Mac 計画と共有）: `#` で始まる行はコメント、空行は無視。`accept <hex> status=<0-4> seq=<0-255> text=<hex または ->`、`reject <hex> <理由>`（理由は `short` / `version` / `status` / `length` / `utf8`）。hex は小文字。空のバイト列は `-`。
- 判定順の取り決め: 複数の規則に当たる入力は、Task 3 の順（short → version → status → length → utf8）で最初の理由を期待値にする。正本がこれと違う理由を書いていたら（テストが落ちたら）、ファームウェアを合わせず、止まって Mac 側の計画の担当とユーザーに報告する（wire contract は parent が持つ）。
- 空の入力 hex の書き方が `-` 以外（例: 空欄）だった場合も、形式の食い違いとして報告し、`decodeHex` を正本に合わせて直す（変えた点を Deviations に書く）。

- [ ] **Step 1: 比較スクリプトを書き、正本が無い・違うと失敗することを確かめる**

`scripts/check-vectors.sh`:

```bash
#!/usr/bin/env bash
# The wire vectors are owned by AgentPets; this repository keeps a byte-exact
# copy. Fails if the AgentPets path is missing or the copies differ.
#   check-vectors.sh <AgentPets repository path>
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# -ne 1 ]]; then
  echo "usage: $0 <AgentPets repository path>" >&2
  exit 2
fi
CANONICAL="$1/Packages/AgentPetsCore/Tests/AgentPetsCoreTests/Fixtures/stackchan/state-record-v1.txt"
LOCAL="$ROOT_DIR/tests/vectors/state-record-v1.txt"

for file in "$CANONICAL" "$LOCAL"; do
  if [[ ! -f "$file" ]]; then
    echo "check-vectors: missing $file" >&2
    exit 1
  fi
done
shasum -a 256 "$CANONICAL" "$LOCAL"
if ! cmp "$CANONICAL" "$LOCAL"; then
  echo "check-vectors: tests/vectors/state-record-v1.txt differs from AgentPets" >&2
  exit 1
fi
echo "check-vectors: identical"
```

```bash
chmod +x scripts/check-vectors.sh
scripts/check-vectors.sh ~/work/tools/AgentPets 2>&1 | tail -3; echo "exit=${PIPESTATUS[0]}"
scripts/check-vectors.sh /nonexistent 2>&1 | tail -2; echo "exit=${PIPESTATUS[0]}"
```

Expected: どちらも `check-vectors: missing ...`、`exit=1`（まだ写していない）。

- [ ] **Step 2: 失敗するテストを書く**

`tests/cpp/state_record_vector_tests.cpp`:

```cpp
// Shared byte vectors for firmware/core/state_record.hpp.
//   state_record_vector_tests <path to tests/vectors/state-record-v1.txt>
// The vector file is the shared contract with AgentPets; a missing or
// malformed file is a failure, never a skip.
#include "state_record.hpp"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <set>
#include <sstream>
#include <string>
#include <vector>

namespace {

int failures = 0;

#define CHECK(condition)                                                      \
  do {                                                                        \
    if (!(condition)) {                                                       \
      std::fprintf(stderr, "%s:%d: CHECK(%s) failed\n", __FILE__, __LINE__, \
                   #condition);                                              \
      ++failures;                                                             \
    }                                                                         \
  } while (false)

using Bytes = std::vector<std::uint8_t>;

// "-" is the empty byte string. Anything other than lowercase hex pairs is
// a malformed vector file.
bool decodeHex(const std::string& hex, Bytes& out) {
  out.clear();
  if (hex == "-") {
    return true;
  }
  if (hex.empty() || hex.size() % 2 != 0) {
    return false;
  }
  for (std::size_t index = 0; index < hex.size(); index += 2) {
    unsigned value = 0;
    for (std::size_t digit = 0; digit < 2; ++digit) {
      const char c = hex[index + digit];
      value <<= 4;
      if (c >= '0' && c <= '9') {
        value |= static_cast<unsigned>(c - '0');
      } else if (c >= 'a' && c <= 'f') {
        value |= static_cast<unsigned>(c - 'a' + 10);
      } else {
        return false;
      }
    }
    out.push_back(static_cast<std::uint8_t>(value));
  }
  return true;
}

bool parseField(const std::string& token, const char* key, std::string& value) {
  const std::string prefix = std::string(key) + "=";
  if (token.compare(0, prefix.size(), prefix) != 0) {
    return false;
  }
  value = token.substr(prefix.size());
  return !value.empty();
}

bool parseInt(const std::string& text, int low, int high, int& value) {
  if (text.empty() || text.size() > 3) {
    return false;
  }
  int parsed = 0;
  for (const char c : text) {
    if (c < '0' || c > '9') {
      return false;
    }
    parsed = parsed * 10 + (c - '0');
  }
  if (parsed < low || parsed > high) {
    return false;
  }
  value = parsed;
  return true;
}

pet::RecordError reasonFromName(const std::string& name, bool& known) {
  known = true;
  if (name == "short") return pet::RecordError::Short;
  if (name == "version") return pet::RecordError::Version;
  if (name == "status") return pet::RecordError::Status;
  if (name == "length") return pet::RecordError::Length;
  if (name == "utf8") return pet::RecordError::Utf8;
  known = false;
  return pet::RecordError::None;
}

pet::ParseResult parse(const Bytes& bytes) {
  return pet::parseStateRecord(bytes.empty() ? nullptr : bytes.data(),
                               bytes.size());
}

void runVectorFile(const char* path) {
  std::ifstream file(path);
  if (!file) {
    std::fprintf(stderr, "vector file unavailable: %s\n", path);
    ++failures;
    return;
  }
  std::set<std::string> rejectReasonsSeen;
  int acceptCount = 0;
  int lineNumber = 0;
  std::string line;
  while (std::getline(file, line)) {
    ++lineNumber;
    if (line.empty() || line[0] == '#') {
      continue;
    }
    std::istringstream fields(line);
    std::string kind;
    std::string hex;
    fields >> kind >> hex;
    Bytes input;
    if (!decodeHex(hex, input)) {
      std::fprintf(stderr, "%s:%d: malformed input hex\n", path, lineNumber);
      ++failures;
      continue;
    }
    const pet::ParseResult result = parse(input);
    if (kind == "accept") {
      std::string statusToken;
      std::string seqToken;
      std::string textToken;
      std::string extra;
      fields >> statusToken >> seqToken >> textToken;
      std::string statusText;
      std::string seqText;
      std::string textHex;
      int status = -1;
      int seq = -1;
      Bytes text;
      if (!parseField(statusToken, "status", statusText) ||
          !parseInt(statusText, 0, 4, status) ||
          !parseField(seqToken, "seq", seqText) ||
          !parseInt(seqText, 0, 255, seq) ||
          !parseField(textToken, "text", textHex) ||
          !decodeHex(textHex, text) || (fields >> extra)) {
        std::fprintf(stderr, "%s:%d: malformed accept line\n", path,
                     lineNumber);
        ++failures;
        continue;
      }
      ++acceptCount;
      if (result.error != pet::RecordError::None) {
        std::fprintf(stderr, "%s:%d: expected accept, got reject %s\n", path,
                     lineNumber, pet::recordErrorName(result.error));
        ++failures;
        continue;
      }
      CHECK(static_cast<int>(result.record.state) == status);
      CHECK(result.record.celebrateSeq == seq);
      CHECK(result.record.textLength == text.size());
      CHECK(text.empty() ||
            std::memcmp(result.record.text, text.data(), text.size()) == 0);
    } else if (kind == "reject") {
      std::string reason;
      std::string extra;
      fields >> reason;
      bool known = false;
      const pet::RecordError expected = reasonFromName(reason, known);
      if (!known || (fields >> extra)) {
        std::fprintf(stderr, "%s:%d: malformed reject line\n", path,
                     lineNumber);
        ++failures;
        continue;
      }
      rejectReasonsSeen.insert(reason);
      if (result.error != expected) {
        std::fprintf(stderr, "%s:%d: expected reject %s, got %s\n", path,
                     lineNumber, reason.c_str(),
                     pet::recordErrorName(result.error));
        ++failures;
      }
    } else {
      std::fprintf(stderr, "%s:%d: unknown line kind\n", path, lineNumber);
      ++failures;
    }
  }
  // The shared file must exercise every rejection rule of spec section 1.3
  // and at least one acceptance.
  const std::set<std::string> allReasons{"short", "version", "status",
                                         "length", "utf8"};
  CHECK(rejectReasonsSeen == allReasons);
  CHECK(acceptCount > 0);
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 2) {
    std::fprintf(stderr, "usage: %s <state-record-v1.txt>\n", argv[0]);
    return 2;
  }
  runVectorFile(argv[1]);
  if (failures != 0) {
    std::fprintf(stderr, "state_record_vector_tests: %d failure(s)\n", failures);
    return 1;
  }
  std::puts("state_record_vector_tests: ok");
  return 0;
}
```

`scripts/check-core.sh` の `run_test state_record_tests` の次に足す:

```bash
run_test state_record_vector_tests tests/vectors/state-record-v1.txt
```

```bash
scripts/check-core.sh 2>&1 | tail -4; echo "exit=${PIPESTATUS[0]}"
```

Expected: `vector file unavailable: tests/vectors/state-record-v1.txt`、`exit=1`。

- [ ] **Step 3: 正本を写して通す**

```bash
mkdir -p tests/vectors
cp ~/work/tools/AgentPets/Packages/AgentPetsCore/Tests/AgentPetsCoreTests/Fixtures/stackchan/state-record-v1.txt tests/vectors/state-record-v1.txt
git -C ~/work/tools/AgentPets log -1 --format='%H %s' -- Packages/AgentPetsCore/Tests/AgentPetsCoreTests/Fixtures/stackchan/state-record-v1.txt
scripts/check-vectors.sh ~/work/tools/AgentPets 2>&1 | tail -3; echo "exit=${PIPESTATUS[0]}"
scripts/check-core.sh 2>&1 | tail -12; echo "exit=${PIPESTATUS[0]}"
```

Expected: `check-vectors: identical`、`state_record_vector_tests: ok`、両方 `exit=0`。落ちた行があれば Interfaces の手順で報告する（ファームウェアも正本も勝手に直さない）。AgentPets 側の commit hash を `docs/provenance.md` に 1 行足す（「`tests/vectors/state-record-v1.txt` は AgentPets <hash> の写し」）。

- [ ] **Step 4: Commit**

```bash
git add tests/vectors/state-record-v1.txt scripts/check-vectors.sh tests/cpp/state_record_vector_tests.cpp scripts/check-core.sh docs/provenance.md
git status --porcelain
git commit -m "Check record parsing against the vectors shared with AgentPets"
```

---

### Task 5: 表示モデルと mailbox

**Files:**
- Create: `firmware/core/pet_display_model.hpp`, `firmware/core/pet_mailbox.hpp`, `firmware/core/record_intake.hpp`
- Test: `tests/cpp/pet_display_model_tests.cpp`
- Modify: `scripts/check-core.sh`

**Interfaces:**
- Consumes: Task 3 の `StateRecord`、`parseStateRecord`
- Produces（`namespace pet`）:
  - `constexpr std::uint32_t kWatchdogMs = 15000`
  - `enum class EventKind : std::uint8_t { None, Record, Disconnect }`、`struct ModelEvent { EventKind kind; std::uint32_t generation; StateRecord record; }`
  - `struct DisplayModel { bool connected; PetState state; std::uint8_t textLength; std::uint8_t text[255]; std::uint32_t contentGeneration; std::uint32_t celebrateGeneration; std::uint32_t celebrateAtMs; }`
  - `class PetDisplayModel { const DisplayModel& update(const ModelEvent&, std::uint32_t nowMs); const DisplayModel& view() const; }`。`update` は先に watchdog を評価し、次に事象を当てる。拒否されたレコードは呼び出し側が `EventKind::None` にして渡す
  - `class PetMailbox { static constexpr std::size_t kCapacity = 260; struct Item { EventKind kind; std::uint32_t generation; std::size_t length; std::uint8_t bytes[260]; }; std::uint32_t onConnect(); void onWrite(const std::uint8_t*, std::size_t); void onDisconnect(); bool take(Item&); }`。排他は呼び出し側（Task 9）が持つ
  - `struct Intake { ModelEvent event; RecordError error; }`、`Intake toModelEvent(const PetMailbox::Item&)`（`record_intake.hpp`）。切断はそのまま `Disconnect`、正しい write は `Record`、拒否された write は `EventKind::None`（表示を変えず watchdog も延長しない、§1.3）。Serial を使わない純粋関数で、スケッチの `RecordIntake.h` はこれにログを足すだけ
- 規則（spec に明記の無い部分の決定。Deviations に記録する）:
  - `contentGeneration` は connected・状態・文のどれかが変わったときだけ増える。描画はこれが動いたときだけやり直す（keep-alive で描かない）
  - 世代番号: 切断の世代が直前に受理したレコードの世代より古ければ無視する。切断済みの世代（以下）のレコードは無視する
  - mailbox は最新の write 1 件と最新の切断 1 件だけ持つ。取り出し順は「同じ世代ならレコード → 切断」「切断より新しい世代のレコードは切断の後」

- [ ] **Step 1: 失敗するテストを書く**

`tests/cpp/pet_display_model_tests.cpp`（期待値は spec §1.3・§1.4・§3.2・§3.6 と成功条件 2・3 から）:

```cpp
// Host tests for pet_display_model.hpp, pet_mailbox.hpp and
// record_intake.hpp (spec 1.3, 1.4,
// 3.2, 3.6).
#include "pet_display_model.hpp"
#include "pet_mailbox.hpp"
#include "record_intake.hpp"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <initializer_list>

namespace {

int failures = 0;

#define CHECK(condition)                                                      \
  do {                                                                        \
    if (!(condition)) {                                                       \
      std::fprintf(stderr, "%s:%d: CHECK(%s) failed\n", __FILE__, __LINE__, \
                   #condition);                                              \
      ++failures;                                                             \
    }                                                                         \
  } while (false)

using pet::EventKind;
using pet::ModelEvent;
using pet::PetDisplayModel;
using pet::PetState;

ModelEvent recordEvent(PetState state, std::uint8_t seq, const char* text,
                       std::uint32_t generation = 1) {
  ModelEvent event{};
  event.kind = EventKind::Record;
  event.generation = generation;
  event.record.state = state;
  event.record.celebrateSeq = seq;
  event.record.textLength = static_cast<std::uint8_t>(std::strlen(text));
  std::memcpy(event.record.text, text, event.record.textLength);
  return event;
}

ModelEvent disconnectEvent(std::uint32_t generation) {
  ModelEvent event{};
  event.kind = EventKind::Disconnect;
  event.generation = generation;
  return event;
}

ModelEvent tick() { return ModelEvent{}; }

bool textIs(const pet::DisplayModel& view, const char* text) {
  return view.textLength == std::strlen(text) &&
         std::memcmp(view.text, text, view.textLength) == 0;
}

void testStartsNeutral() {
  PetDisplayModel model;
  const auto& view = model.update(tick(), 0);
  CHECK(!view.connected);
  CHECK(view.contentGeneration == 0);
  CHECK(view.celebrateGeneration == 0);
}

void testFirstAcceptDoesNotCelebrate() {
  PetDisplayModel model;
  const auto& view = model.update(recordEvent(PetState::Success, 9, "done"), 100);
  CHECK(view.connected);
  CHECK(view.state == PetState::Success);
  CHECK(textIs(view, "done"));
  CHECK(view.celebrateGeneration == 0);
  CHECK(view.contentGeneration == 1);
}

void testCelebrateOnSeqChangeOnlyInSuccess() {
  PetDisplayModel model;
  model.update(recordEvent(PetState::Working, 0, "a"), 0);
  // Same seq while success: no celebrate.
  model.update(recordEvent(PetState::Success, 0, "a"), 100);
  CHECK(model.view().celebrateGeneration == 0);
  // Seq changes while success: exactly one celebrate.
  model.update(recordEvent(PetState::Success, 1, "a"), 200);
  CHECK(model.view().celebrateGeneration == 1);
  CHECK(model.view().celebrateAtMs == 200);
  // Keep-alive with the same seq: no second celebrate.
  model.update(recordEvent(PetState::Success, 1, "a"), 5200);
  CHECK(model.view().celebrateGeneration == 1);
  // Seq changes but the state is not success: no celebrate, seq remembered.
  model.update(recordEvent(PetState::Working, 2, "a"), 5300);
  CHECK(model.view().celebrateGeneration == 1);
  model.update(recordEvent(PetState::Success, 2, "a"), 5400);
  CHECK(model.view().celebrateGeneration == 1);
}

void testSeqWrapCelebrates() {
  PetDisplayModel model;
  model.update(recordEvent(PetState::Success, 255, ""), 0);
  model.update(recordEvent(PetState::Success, 0, ""), 100);
  CHECK(model.view().celebrateGeneration == 1);
}

void testDroppedCelebrateRecoversOnKeepAlive() {
  // Spec success criterion 2: the celebrate record is lost, the next
  // keep-alive still in success carries the new seq and celebrates late.
  PetDisplayModel model;
  model.update(recordEvent(PetState::Working, 4, "x"), 0);
  model.update(recordEvent(PetState::Success, 5, "x"), 5000);
  CHECK(model.view().celebrateGeneration == 1);
}

void testKeepAliveDoesNotRedraw() {
  PetDisplayModel model;
  model.update(recordEvent(PetState::Working, 0, "edit"), 0);
  const std::uint32_t before = model.view().contentGeneration;
  model.update(recordEvent(PetState::Working, 0, "edit"), 5000);
  CHECK(model.view().contentGeneration == before);
  model.update(recordEvent(PetState::Working, 0, "edit2"), 6000);
  CHECK(model.view().contentGeneration == before + 1);
  model.update(recordEvent(PetState::Waiting, 0, "edit2"), 7000);
  CHECK(model.view().contentGeneration == before + 2);
}

void testWatchdogBoundary() {
  PetDisplayModel model;
  model.update(recordEvent(PetState::Working, 0, ""), 1000);
  model.update(tick(), 1000 + 14900);
  CHECK(model.view().connected);
  model.update(tick(), 1000 + 14999);
  CHECK(model.view().connected);
  model.update(tick(), 1000 + 15000);
  CHECK(!model.view().connected);
}

void testWatchdogAcrossMillisWrap() {
  PetDisplayModel model;
  const std::uint32_t start = 0xFFFFFFFFu - 5000u;
  model.update(recordEvent(PetState::Working, 0, ""), start);
  model.update(tick(), start + 14900u);  // wraps past zero
  CHECK(model.view().connected);
  model.update(tick(), start + 15000u);
  CHECK(!model.view().connected);
}

pet::PetMailbox::Item writeItem(std::initializer_list<std::uint8_t> bytes,
                               std::uint32_t generation = 1) {
  pet::PetMailbox::Item item{};
  item.kind = EventKind::Record;
  item.generation = generation;
  for (const std::uint8_t byte : bytes) {
    item.bytes[item.length++] = byte;
  }
  return item;
}

void testIntakeTurnsValidWriteIntoRecord() {
  const auto intake = pet::toModelEvent(writeItem({1, 3, 9, 2, 'o', 'k'}, 4));
  CHECK(intake.error == pet::RecordError::None);
  CHECK(intake.event.kind == EventKind::Record);
  CHECK(intake.event.generation == 4);
  CHECK(intake.event.record.state == PetState::Success);
  CHECK(intake.event.record.celebrateSeq == 9);
  CHECK(intake.event.record.textLength == 2);
  CHECK(intake.event.record.text[0] == 'o' && intake.event.record.text[1] == 'k');
}

void testIntakeTurnsRejectedWriteIntoNone() {
  // 02010000: version 2 (spec 1.3 rejects it).
  const auto intake = pet::toModelEvent(writeItem({2, 1, 0, 0}, 4));
  CHECK(intake.error == pet::RecordError::Version);
  CHECK(intake.event.kind == EventKind::None);
}

void testIntakeKeepsDisconnect() {
  pet::PetMailbox::Item item{};
  item.kind = EventKind::Disconnect;
  item.generation = 7;
  const auto intake = pet::toModelEvent(item);
  CHECK(intake.event.kind == EventKind::Disconnect);
  CHECK(intake.event.generation == 7);
}

void testRejectedRecordsDoNotChangeOrExtend() {
  // Spec 1.3: a rejected record changes nothing and does not extend the
  // watchdog. Feed real rejected writes through the intake, not plain ticks.
  PetDisplayModel model;
  model.update(pet::toModelEvent(writeItem({1, 1, 0, 1, 'a'})).event, 0);
  CHECK(model.view().connected);
  const std::uint32_t generationBefore = model.view().contentGeneration;
  for (std::uint32_t at = 1000; at < 15000; at += 1000) {
    // version 2 claiming success with different text
    model.update(pet::toModelEvent(writeItem({2, 3, 5, 1, 'b'})).event, at);
    CHECK(model.view().connected);
    CHECK(model.view().state == PetState::Working);
    CHECK(textIs(model.view(), "a"));
    CHECK(model.view().contentGeneration == generationBefore);
    CHECK(model.view().celebrateGeneration == 0);
  }
  model.update(pet::toModelEvent(writeItem({2, 1, 0, 0})).event, 15000);
  CHECK(!model.view().connected);
}

void testRecordAfterTimeoutIsFirstAgain() {
  PetDisplayModel model;
  model.update(recordEvent(PetState::Success, 1, ""), 0);
  model.update(tick(), 15000);
  CHECK(!model.view().connected);
  // New seq while success, but this is the first record after the timeout.
  model.update(recordEvent(PetState::Success, 2, ""), 16000);
  CHECK(model.view().connected);
  CHECK(model.view().celebrateGeneration == 0);
  model.update(recordEvent(PetState::Success, 3, ""), 17000);
  CHECK(model.view().celebrateGeneration == 1);
}

void testLateRecordAfterSilenceIsFirstWithoutTick() {
  // No tick in between: the watchdog still applies before the record.
  PetDisplayModel model;
  model.update(recordEvent(PetState::Success, 1, ""), 0);
  model.update(recordEvent(PetState::Success, 2, ""), 20000);
  CHECK(model.view().connected);
  CHECK(model.view().celebrateGeneration == 0);
}

void testDisconnectIsImmediateAndResetsFirst() {
  PetDisplayModel model;
  model.update(recordEvent(PetState::Success, 1, "", 1), 0);
  model.update(disconnectEvent(1), 10);
  CHECK(!model.view().connected);
  model.update(recordEvent(PetState::Success, 2, "", 2), 20);
  CHECK(model.view().connected);
  CHECK(model.view().celebrateGeneration == 0);
}

void testStaleDisconnectDoesNotClearNewConnection() {
  PetDisplayModel model;
  model.update(recordEvent(PetState::Working, 0, "", 2), 0);
  model.update(disconnectEvent(1), 10);
  CHECK(model.view().connected);
  model.update(disconnectEvent(2), 20);
  CHECK(!model.view().connected);
}

void testStaleRecordAfterDisconnectIsIgnored() {
  PetDisplayModel model;
  model.update(recordEvent(PetState::Working, 0, "", 1), 0);
  model.update(disconnectEvent(1), 10);
  model.update(recordEvent(PetState::Error, 0, "", 1), 20);
  CHECK(!model.view().connected);
}

pet::PetMailbox::Item takeOrEmpty(pet::PetMailbox& box, bool& got) {
  pet::PetMailbox::Item item{};
  got = box.take(item);
  return item;
}

void testMailboxKeepsLatestWrite() {
  pet::PetMailbox box;
  const std::uint32_t generation = box.onConnect();
  const std::uint8_t first[] = {1, 0, 0, 0};
  const std::uint8_t second[] = {1, 1, 0, 0};
  box.onWrite(first, sizeof(first));
  box.onWrite(second, sizeof(second));
  bool got = false;
  const auto item = takeOrEmpty(box, got);
  CHECK(got);
  CHECK(item.kind == EventKind::Record);
  CHECK(item.generation == generation);
  CHECK(item.length == 4 && item.bytes[1] == 1);
  takeOrEmpty(box, got);
  CHECK(!got);
}

void testMailboxOrdersOldDisconnectBeforeNewRecord() {
  // Spec 3.6: the old connection's disconnect must not erase the new one.
  pet::PetMailbox box;
  const std::uint32_t g1 = box.onConnect();
  box.onDisconnect();
  const std::uint32_t g2 = box.onConnect();
  const std::uint8_t bytes[] = {1, 1, 0, 0};
  box.onWrite(bytes, sizeof(bytes));

  PetDisplayModel model;
  bool got = false;
  const auto a = takeOrEmpty(box, got);
  CHECK(got && a.kind == EventKind::Disconnect && a.generation == g1);
  const auto b = takeOrEmpty(box, got);
  CHECK(got && b.kind == EventKind::Record && b.generation == g2);

  model.update(disconnectEvent(a.generation), 0);
  const auto parsed = pet::parseStateRecord(b.bytes, b.length);
  CHECK(parsed.error == pet::RecordError::None);
  ModelEvent event{};
  event.kind = EventKind::Record;
  event.generation = b.generation;
  event.record = parsed.record;
  model.update(event, 1);
  CHECK(model.view().connected);
}

void testMailboxOrdersSameGenerationRecordBeforeDisconnect() {
  pet::PetMailbox box;
  const std::uint32_t g1 = box.onConnect();
  const std::uint8_t bytes[] = {1, 1, 0, 0};
  box.onWrite(bytes, sizeof(bytes));
  box.onDisconnect();
  bool got = false;
  const auto a = takeOrEmpty(box, got);
  CHECK(got && a.kind == EventKind::Record && a.generation == g1);
  const auto b = takeOrEmpty(box, got);
  CHECK(got && b.kind == EventKind::Disconnect && b.generation == g1);
}

void testMailboxKeepsOverlongWriteRejectable() {
  pet::PetMailbox box;
  box.onConnect();
  std::uint8_t big[300];
  std::memset(big, 'x', sizeof(big));
  big[0] = 1;
  big[1] = 0;
  big[2] = 0;
  big[3] = 255;
  box.onWrite(big, sizeof(big));
  bool got = false;
  const auto item = takeOrEmpty(box, got);
  CHECK(got && item.length == pet::PetMailbox::kCapacity);
  CHECK(pet::parseStateRecord(item.bytes, item.length).error ==
        pet::RecordError::Length);
}

}  // namespace

int main() {
  testStartsNeutral();
  testFirstAcceptDoesNotCelebrate();
  testCelebrateOnSeqChangeOnlyInSuccess();
  testSeqWrapCelebrates();
  testDroppedCelebrateRecoversOnKeepAlive();
  testKeepAliveDoesNotRedraw();
  testWatchdogBoundary();
  testWatchdogAcrossMillisWrap();
  testIntakeTurnsValidWriteIntoRecord();
  testIntakeTurnsRejectedWriteIntoNone();
  testIntakeKeepsDisconnect();
  testRejectedRecordsDoNotChangeOrExtend();
  testRecordAfterTimeoutIsFirstAgain();
  testLateRecordAfterSilenceIsFirstWithoutTick();
  testDisconnectIsImmediateAndResetsFirst();
  testStaleDisconnectDoesNotClearNewConnection();
  testStaleRecordAfterDisconnectIsIgnored();
  testMailboxKeepsLatestWrite();
  testMailboxOrdersOldDisconnectBeforeNewRecord();
  testMailboxOrdersSameGenerationRecordBeforeDisconnect();
  testMailboxKeepsOverlongWriteRejectable();
  if (failures != 0) {
    std::fprintf(stderr, "pet_display_model_tests: %d failure(s)\n", failures);
    return 1;
  }
  std::puts("pet_display_model_tests: ok");
  return 0;
}
```

`scripts/check-core.sh` のベクタの行の次に足す:

```bash
run_test pet_display_model_tests
```

```bash
scripts/check-core.sh 2>&1 | tail -4; echo "exit=${PIPESTATUS[0]}"
```

Expected: `fatal error: 'pet_display_model.hpp' file not found`、`exit=1`。

- [ ] **Step 2: 実装する**

`firmware/core/pet_display_model.hpp`:

```cpp
#pragma once

#include "state_record.hpp"

#include <cstdint>
#include <cstring>

namespace pet {

// Spec section 1.4: no accepted record for this long means "not connected".
constexpr std::uint32_t kWatchdogMs = 15000;

enum class EventKind : std::uint8_t {
  None,        // time passes (watchdog check only)
  Record,      // an accepted record from connection `generation`
  Disconnect,  // connection `generation` closed
};

struct ModelEvent {
  EventKind kind = EventKind::None;
  std::uint32_t generation = 0;
  StateRecord record{};
};

struct DisplayModel {
  // false: neutral face and the word for "not connected".
  bool connected = false;
  PetState state = PetState::Idle;
  std::uint8_t textLength = 0;
  std::uint8_t text[kTextCapacity] = {};
  // Bumped when connected/state/text change. Keep-alives leave it alone, so
  // the renderer redraws only when this moves.
  std::uint32_t contentGeneration = 0;
  // Bumped once per celebrate; celebrateAtMs is when it happened.
  std::uint32_t celebrateGeneration = 0;
  std::uint32_t celebrateAtMs = 0;
};

class PetDisplayModel {
 public:
  const DisplayModel& update(const ModelEvent& event, std::uint32_t nowMs) {
    // The watchdog runs first so that a record arriving after a long silence
    // is treated as the first record (spec section 3.2).
    if (view_.connected &&
        static_cast<std::uint32_t>(nowMs - lastAcceptMs_) >= kWatchdogMs) {
      goNeutral();
    }
    switch (event.kind) {
      case EventKind::None:
        break;
      case EventKind::Record:
        if (hasClosed_ && event.generation <= closedGeneration_) {
          break;  // late record from a connection that already closed
        }
        accept(event.record, event.generation, nowMs);
        break;
      case EventKind::Disconnect:
        if (hasRecordGeneration_ && event.generation < recordGeneration_) {
          break;  // late disconnect of an older connection
        }
        if (!hasClosed_ || event.generation > closedGeneration_) {
          closedGeneration_ = event.generation;
          hasClosed_ = true;
        }
        goNeutral();
        break;
    }
    return view_;
  }

  const DisplayModel& view() const { return view_; }

 private:
  void accept(const StateRecord& record, std::uint32_t generation,
              std::uint32_t nowMs) {
    const bool first = awaitingFirst_;
    const bool celebrate = !first && record.state == PetState::Success &&
                           record.celebrateSeq != lastSeq_;
    const bool contentChanged =
        !view_.connected || record.state != view_.state ||
        record.textLength != view_.textLength ||
        std::memcmp(record.text, view_.text, record.textLength) != 0;

    lastSeq_ = record.celebrateSeq;
    lastAcceptMs_ = nowMs;
    awaitingFirst_ = false;
    recordGeneration_ = generation;
    hasRecordGeneration_ = true;

    if (contentChanged) {
      view_.connected = true;
      view_.state = record.state;
      view_.textLength = record.textLength;
      std::memcpy(view_.text, record.text, record.textLength);
      ++view_.contentGeneration;
    }
    if (celebrate) {
      ++view_.celebrateGeneration;
      view_.celebrateAtMs = nowMs;
    }
  }

  void goNeutral() {
    awaitingFirst_ = true;
    if (view_.connected) {
      view_.connected = false;
      ++view_.contentGeneration;
    }
  }

  DisplayModel view_{};
  bool awaitingFirst_ = true;
  std::uint8_t lastSeq_ = 0;
  std::uint32_t lastAcceptMs_ = 0;
  bool hasRecordGeneration_ = false;
  std::uint32_t recordGeneration_ = 0;
  bool hasClosed_ = false;
  std::uint32_t closedGeneration_ = 0;
};

}  // namespace pet
```

`firmware/core/pet_mailbox.hpp`:

```cpp
#pragma once

#include "pet_display_model.hpp"
#include "state_record.hpp"

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace pet {

// Hand-off from the NimBLE host task to the main loop. Not thread-safe by
// itself: the caller wraps every call in the same critical section.
// Holds only the latest write and the latest disconnect, each tagged with the
// connection generation that produced it.
class PetMailbox {
 public:
  // One byte more than the longest valid record, so a longer write is kept
  // as an over-long record that fails the L check instead of being cut into
  // something valid.
  static constexpr std::size_t kCapacity = kRecordMaxLength + 1;

  struct Item {
    EventKind kind = EventKind::None;
    std::uint32_t generation = 0;
    std::size_t length = 0;
    std::uint8_t bytes[kCapacity] = {};
  };

  std::uint32_t onConnect() { return ++generation_; }

  void onWrite(const std::uint8_t* data, std::size_t length) {
    const std::size_t kept = length < kCapacity ? length : kCapacity;
    if (data != nullptr && kept > 0) {
      std::memcpy(record_.bytes, data, kept);
    }
    record_.length = kept;
    record_.generation = generation_;
    record_.kind = EventKind::Record;
    recordPending_ = true;
  }

  void onDisconnect() {
    disconnectGeneration_ = generation_;
    disconnectPending_ = true;
  }

  // Within one generation, writes happened before its disconnect; a record
  // from a newer generation happened after an older disconnect.
  bool take(Item& out) {
    if (disconnectPending_ &&
        (!recordPending_ || record_.generation > disconnectGeneration_)) {
      out = Item{};
      out.kind = EventKind::Disconnect;
      out.generation = disconnectGeneration_;
      disconnectPending_ = false;
      return true;
    }
    if (recordPending_) {
      out = record_;
      recordPending_ = false;
      return true;
    }
    return false;
  }

  std::uint32_t generation() const { return generation_; }

 private:
  std::uint32_t generation_ = 0;
  Item record_{};
  bool recordPending_ = false;
  std::uint32_t disconnectGeneration_ = 0;
  bool disconnectPending_ = false;
};

}  // namespace pet
```

`firmware/core/record_intake.hpp`:

```cpp
#pragma once

#include "pet_display_model.hpp"
#include "pet_mailbox.hpp"
#include "state_record.hpp"

namespace pet {

struct Intake {
  ModelEvent event{};
  // Parse result for a write; None for a disconnect.
  RecordError error = RecordError::None;
};

// Mailbox item -> model event. A rejected write becomes EventKind::None, so
// the model only runs its watchdog: the display does not change and the
// watchdog is not extended (spec 1.3).
inline Intake toModelEvent(const PetMailbox::Item& item) {
  Intake intake{};
  intake.event.generation = item.generation;
  if (item.kind == EventKind::Disconnect) {
    intake.event.kind = EventKind::Disconnect;
    return intake;
  }
  const ParseResult parsed = parseStateRecord(item.bytes, item.length);
  intake.error = parsed.error;
  if (parsed.error != RecordError::None) {
    intake.event.kind = EventKind::None;
    return intake;
  }
  intake.event.kind = EventKind::Record;
  intake.event.record = parsed.record;
  return intake;
}

}  // namespace pet
```

- [ ] **Step 3: 通ることを確かめる**

```bash
scripts/check-core.sh 2>&1 | tail -12; echo "exit=${PIPESTATUS[0]}"
```

Expected: `pet_display_model_tests: ok`、`exit=0`。

- [ ] **Step 4: Commit**

```bash
git add firmware/core/pet_display_model.hpp firmware/core/pet_mailbox.hpp firmware/core/record_intake.hpp tests/cpp/pet_display_model_tests.cpp scripts/check-core.sh
git status --porcelain
git commit -m "Derive the pet display from records, disconnects and a 15 s watchdog"
```

- [ ] **Step 5: 判定が効いていることを確かめる（変異、commit の後）**

Task 3 Step 5 と同じ手順。

| 変異 | 落ちるべきテスト |
|---|---|
| `>= kWatchdogMs` を `> kWatchdogMs` | `testWatchdogBoundary` |
| `event.generation <= closedGeneration_` を `<` | `testStaleRecordAfterDisconnectIsIgnored` |
| `event.generation < recordGeneration_` を `false` | `testStaleDisconnectDoesNotClearNewConnection` |
| `record.celebrateSeq != lastSeq_` を `true` | `testCelebrateOnSeqChangeOnlyInSuccess` |
| `const bool first = awaitingFirst_;` を `= false;` | `testFirstAcceptDoesNotCelebrate` ほか |
| mailbox の `record_.generation > disconnectGeneration_` を `>=` | `testMailboxOrdersSameGenerationRecordBeforeDisconnect` |
| `record_intake.hpp` の `intake.event.kind = EventKind::None;` を `= EventKind::Record; intake.event.record = parsed.record;` | `testIntakeTurnsRejectedWriteIntoNone`、`testRejectedRecordsDoNotChangeOrExtend` |
| `record_intake.hpp` の `if (parsed.error != RecordError::None) {` を `if (false) {` | 同上 |

計画作成時に scratch で全部が落ちることを確認済み。

---

### Task 6: サーボ電源の読み戻し判定

**Files:**
- Create: `firmware/core/servo_power_check.hpp`
- Test: `tests/cpp/servo_power_check_tests.cpp`
- Modify: `scripts/check-core.sh`

**Interfaces:**
- Produces（`namespace pet`）:
  - `constexpr std::uint8_t kPy32FirstGpioRegister = 0x03`、`constexpr std::size_t kPy32GpioRegisterCount = 10`
  - `struct ServoPowerReadback { bool valid; std::uint16_t mode, out, pu, pd; }`（spec §3.4 の `{valid, mode, out, pu, pd}`）
  - `ServoPowerReadback decodeServoPowerReadback(bool readOk, const std::uint8_t (&raw)[10])`（`readOk == false` ならバイトを読まず全部 0）
  - `enum class ServoPowerVerdict : std::uint8_t { Off, ReadFailed, OutputHigh, NotOutput, PullNotDown }`、`ServoPowerVerdict judgeServoPower(const ServoPowerReadback&)`、`const char* servoPowerVerdictName(ServoPowerVerdict)`
  - `kServoPowerSingleRegisters[4] = {0x03, 0x05, 0x09, 0x0B}`、`kServoPowerSingleIndices[4] = {0, 2, 6, 8}`、`struct CombinedReadback { bool consistent; ServoPowerReadback readback; ServoPowerVerdict verdict; bool writeBaseValid; std::uint8_t writeBase[10]; }`、`CombinedReadback combineReadback(bool blockOk, const std::uint8_t (&block)[10], bool singlesOk, const std::uint8_t (&singles)[4])`。まとめ読みと単独読みが両方成功して一致したときだけ判定に `valid` を渡す（食い違い・どちらかの失敗は fault）。OFF の書き込みの元は単独読みが成功していれば作り、4 つの low byte は単独読みの値を使う
- **spec からの補足（Deviations に記録する）:** PY32 がまとめ読み（0x03〜0x0C）でアドレスを進めて返すかは未検証（PoC は 1 バイトずつ読んでいた）。そのため spec §3.4 のまとめ読みに単独読みの照合を足す。照合と「書く値を単独読みから作る」規則は spec §3.6 に従い core の純粋関数にしてホストでテストする（SafeBoard は I2C を読んで渡すだけ）
- fault（`Off` 以外）になる条件は spec §3.6 のとおり: valid=false、out の pin0 が 1、mode の pin0 が出力でない、pin0 のプルが「pull-up off・pull-down on」でない。判定順はこの並び。

- [ ] **Step 1: 失敗するテストを書く**

`tests/cpp/servo_power_check_tests.cpp`:

```cpp
// Host tests for servo_power_check.hpp (spec 3.4, 3.6).
#include "servo_power_check.hpp"

#include <cstdint>
#include <cstdio>

namespace {

int failures = 0;

#define CHECK(condition)                                                      \
  do {                                                                        \
    if (!(condition)) {                                                       \
      std::fprintf(stderr, "%s:%d: CHECK(%s) failed\n", __FILE__, __LINE__, \
                   #condition);                                              \
      ++failures;                                                             \
    }                                                                         \
  } while (false)

using pet::ServoPowerVerdict;

// Raw block in register order 0x03..0x0C.
struct Raw {
  std::uint8_t modeL, modeH, outL, outH, inL, inH, puL, puH, pdL, pdH;
};

pet::ServoPowerReadback decode(bool ok, const Raw& r) {
  const std::uint8_t raw[pet::kPy32GpioRegisterCount] = {
      r.modeL, r.modeH, r.outL, r.outH, r.inL, r.inH, r.puL, r.puH, r.pdL, r.pdH};
  return pet::decodeServoPowerReadback(ok, raw);
}

// Pin 0 written in the spec order: out 0, pull-up off, pull-down on, output.
// Other bits are arbitrary and must not matter.
constexpr Raw kOff{0x01 | 0x20, 0x20, 0x00 | 0x40, 0xff, 0x01, 0x00,
                   0x00 | 0x80, 0x20, 0x01 | 0x02, 0x00};

void testRegisterOrderDecoding() {
  const Raw distinct{0x11, 0x12, 0x21, 0x22, 0x31, 0x32, 0x41, 0x42, 0x51, 0x52};
  const auto readback = decode(true, distinct);
  CHECK(readback.valid);
  CHECK(readback.mode == 0x1211);
  CHECK(readback.out == 0x2221);
  CHECK(readback.pu == 0x4241);
  CHECK(readback.pd == 0x5251);
}

void testFailedReadIsNeverOff() {
  // Even all-zero bytes from a failed transfer must not look like "output 0".
  const auto readback = decode(false, kOff);
  CHECK(!readback.valid);
  CHECK(readback.mode == 0 && readback.out == 0 && readback.pu == 0 &&
        readback.pd == 0);
  CHECK(pet::judgeServoPower(readback) == ServoPowerVerdict::ReadFailed);
}

void testOffIsAccepted() {
  CHECK(pet::judgeServoPower(decode(true, kOff)) == ServoPowerVerdict::Off);
}

void testEachFaultCondition() {
  Raw outHigh = kOff;
  outHigh.outL |= 0x01;
  CHECK(pet::judgeServoPower(decode(true, outHigh)) ==
        ServoPowerVerdict::OutputHigh);

  Raw input = kOff;
  input.modeL &= static_cast<std::uint8_t>(~0x01);
  CHECK(pet::judgeServoPower(decode(true, input)) ==
        ServoPowerVerdict::NotOutput);

  Raw pullUp = kOff;
  pullUp.puL |= 0x01;
  CHECK(pet::judgeServoPower(decode(true, pullUp)) ==
        ServoPowerVerdict::PullNotDown);

  Raw noPull = kOff;
  noPull.pdL &= static_cast<std::uint8_t>(~0x01);
  CHECK(pet::judgeServoPower(decode(true, noPull)) ==
        ServoPowerVerdict::PullNotDown);

  // The PoC beginSafeBoard state (output, pull-up) is a fault here.
  Raw pocState = kOff;
  pocState.puL |= 0x01;
  pocState.pdL &= static_cast<std::uint8_t>(~0x01);
  CHECK(pet::judgeServoPower(decode(true, pocState)) ==
        ServoPowerVerdict::PullNotDown);
}

void testOnlyPinZeroMatters() {
  // High-byte bit 0 is pin 8, not VM EN.
  Raw highByte = kOff;
  highByte.outH = 0x01;
  highByte.modeH = 0x00;
  highByte.puH = 0x01;
  highByte.pdH = 0x00;
  CHECK(pet::judgeServoPower(decode(true, highByte)) == ServoPowerVerdict::Off);
  // Input register is ignored, whatever level pin 0 reads.
  Raw inputHigh = kOff;
  inputHigh.inL = 0x01;
  CHECK(pet::judgeServoPower(decode(true, inputHigh)) == ServoPowerVerdict::Off);
  Raw inputLow = kOff;
  inputLow.inL = 0x00;
  CHECK(pet::judgeServoPower(decode(true, inputLow)) == ServoPowerVerdict::Off);
}


struct Singles {
  std::uint8_t modeL, outL, puL, pdL;
};

pet::CombinedReadback combine(bool blockOk, const Raw& r, bool singlesOk,
                              const Singles& s) {
  const std::uint8_t block[pet::kPy32GpioRegisterCount] = {
      r.modeL, r.modeH, r.outL, r.outH, r.inL, r.inH, r.puL, r.puH, r.pdL, r.pdH};
  const std::uint8_t singles[pet::kServoPowerSingleCount] = {s.modeL, s.outL,
                                                             s.puL, s.pdL};
  return pet::combineReadback(blockOk, block, singlesOk, singles);
}

constexpr Singles kOffSingles{kOff.modeL, kOff.outL, kOff.puL, kOff.pdL};

void testSingleRegistersMatchTheBlockLayout() {
  // Register numbers from the BSP register map: block starts at 0x03.
  for (std::size_t i = 0; i < pet::kServoPowerSingleCount; ++i) {
    CHECK(pet::kServoPowerSingleRegisters[i] ==
          pet::kPy32FirstGpioRegister + pet::kServoPowerSingleIndices[i]);
  }
  CHECK(pet::kServoPowerSingleRegisters[0] == 0x03);  // mode low
  CHECK(pet::kServoPowerSingleRegisters[1] == 0x05);  // output low
  CHECK(pet::kServoPowerSingleRegisters[2] == 0x09);  // pull-up low
  CHECK(pet::kServoPowerSingleRegisters[3] == 0x0B);  // pull-down low
}

void testCombinedOffNeedsAgreement() {
  const auto agree = combine(true, kOff, true, kOffSingles);
  CHECK(agree.consistent);
  CHECK(agree.verdict == ServoPowerVerdict::Off);
  // Block says OFF, the single read of the output register says 1.
  Singles outHigh = kOffSingles;
  outHigh.outL |= 0x01;
  const auto mismatch = combine(true, kOff, true, outHigh);
  CHECK(!mismatch.consistent);
  CHECK(mismatch.verdict != ServoPowerVerdict::Off);
  // Any other low byte disagreeing is a fault too.
  Singles pdDiffers = kOffSingles;
  pdDiffers.pdL ^= 0x80;
  CHECK(combine(true, kOff, true, pdDiffers).verdict != ServoPowerVerdict::Off);
  // Either read failing is a fault.
  CHECK(combine(false, kOff, true, kOffSingles).verdict ==
        ServoPowerVerdict::ReadFailed);
  CHECK(combine(true, kOff, false, kOffSingles).verdict ==
        ServoPowerVerdict::ReadFailed);
}

void testWriteBaseComesFromSingleReads() {
  // Block failed, singles fine: OFF can still be written, from the singles.
  const Singles singles{0x20, 0x41, 0x80, 0x02};
  const auto blockFailed = combine(false, kOff, true, singles);
  CHECK(blockFailed.writeBaseValid);
  CHECK(blockFailed.writeBase[0] == 0x20);
  CHECK(blockFailed.writeBase[2] == 0x41);
  CHECK(blockFailed.writeBase[6] == 0x80);
  CHECK(blockFailed.writeBase[8] == 0x02);
  // Block and singles disagree: the singles win for the four low bytes.
  const auto mismatch = combine(true, kOff, true, singles);
  CHECK(mismatch.writeBaseValid);
  CHECK(mismatch.writeBase[2] == 0x41);
  CHECK(mismatch.writeBase[3] == kOff.outH);  // other bytes from the block
  // Singles failed: nothing to build a write on.
  CHECK(!combine(true, kOff, false, singles).writeBaseValid);
}

}  // namespace

int main() {
  testRegisterOrderDecoding();
  testFailedReadIsNeverOff();
  testOffIsAccepted();
  testEachFaultCondition();
  testOnlyPinZeroMatters();
  testSingleRegistersMatchTheBlockLayout();
  testCombinedOffNeedsAgreement();
  testWriteBaseComesFromSingleReads();
  if (failures != 0) {
    std::fprintf(stderr, "servo_power_check_tests: %d failure(s)\n", failures);
    return 1;
  }
  std::puts("servo_power_check_tests: ok");
  return 0;
}
```

`scripts/check-core.sh` の `run_test pet_display_model_tests` の次に足す:

```bash
run_test servo_power_check_tests
```

```bash
scripts/check-core.sh 2>&1 | tail -4; echo "exit=${PIPESTATUS[0]}"
```

Expected: `fatal error: 'servo_power_check.hpp' file not found`、`exit=1`。

- [ ] **Step 2: 実装する**

`firmware/core/servo_power_check.hpp`:

```cpp
#pragma once

#include <cstddef>
#include <cstdint>

namespace pet {

// PY32 IO expander GPIO configuration block, read in one transfer starting at
// register 0x03 (vendor/StackChan-BSP PY32 register map):
//   0x03/0x04 mode (1 = output)   0x05/0x06 output value
//   0x07/0x08 input level         0x09/0x0A pull-up enable
//   0x0B/0x0C pull-down enable
// Servo power enable (VM EN) is pin 0 = bit 0 of each low byte.
constexpr std::uint8_t kPy32FirstGpioRegister = 0x03;
constexpr std::size_t kPy32GpioRegisterCount = 10;
constexpr std::uint16_t kServoPowerPinMask = 0x0001;

struct ServoPowerReadback {
  bool valid = false;
  std::uint16_t mode = 0;
  std::uint16_t out = 0;
  std::uint16_t pu = 0;
  std::uint16_t pd = 0;
};

inline ServoPowerReadback decodeServoPowerReadback(
    bool readOk, const std::uint8_t (&raw)[kPy32GpioRegisterCount]) {
  ServoPowerReadback readback{};
  readback.valid = readOk;
  if (!readOk) {
    return readback;  // never interpret bytes from a failed transfer
  }
  const auto word = [&raw](std::size_t lowIndex) {
    return static_cast<std::uint16_t>(raw[lowIndex] |
                                      (static_cast<unsigned>(raw[lowIndex + 1]) << 8));
  };
  readback.mode = word(0);  // 0x03/0x04
  readback.out = word(2);   // 0x05/0x06
  readback.pu = word(6);    // 0x09/0x0A
  readback.pd = word(8);    // 0x0B/0x0C
  return readback;
}

// First matching reason wins, in this order.
enum class ServoPowerVerdict : std::uint8_t {
  Off,          // output 0, pin is an output, pull-up off and pull-down on
  ReadFailed,   // the I2C read did not complete
  OutputHigh,   // output latch bit 0 is 1
  NotOutput,    // pin 0 is not configured as an output
  PullNotDown,  // pull is not "pull-up off, pull-down on"
};

inline ServoPowerVerdict judgeServoPower(const ServoPowerReadback& readback) {
  if (!readback.valid) {
    return ServoPowerVerdict::ReadFailed;
  }
  if ((readback.out & kServoPowerPinMask) != 0) {
    return ServoPowerVerdict::OutputHigh;
  }
  if ((readback.mode & kServoPowerPinMask) == 0) {
    return ServoPowerVerdict::NotOutput;
  }
  if ((readback.pu & kServoPowerPinMask) != 0 ||
      (readback.pd & kServoPowerPinMask) == 0) {
    return ServoPowerVerdict::PullNotDown;
  }
  return ServoPowerVerdict::Off;
}

// The four low bytes that decide pin 0, read one register at a time to
// cross-check the block read (PY32 auto-increment on block reads is
// unverified), and their index inside the block.
constexpr std::size_t kServoPowerSingleCount = 4;
constexpr std::uint8_t kServoPowerSingleRegisters[kServoPowerSingleCount] = {
    0x03, 0x05, 0x09, 0x0B};  // mode, output, pull-up, pull-down (low bytes)
constexpr std::size_t kServoPowerSingleIndices[kServoPowerSingleCount] = {0, 2, 6, 8};

struct CombinedReadback {
  bool consistent = false;  // block and singles both read and equal
  ServoPowerReadback readback{};
  ServoPowerVerdict verdict = ServoPowerVerdict::ReadFailed;
  // What an OFF write builds on: the block with the four low bytes taken
  // from the single reads, so OFF can be written even if the block read
  // misbehaves. Valid when the single reads succeeded.
  bool writeBaseValid = false;
  std::uint8_t writeBase[kPy32GpioRegisterCount] = {};
};

inline CombinedReadback combineReadback(
    bool blockOk, const std::uint8_t (&block)[kPy32GpioRegisterCount],
    bool singlesOk, const std::uint8_t (&singles)[kServoPowerSingleCount]) {
  CombinedReadback combined{};
  combined.consistent = blockOk && singlesOk;
  for (std::size_t i = 0; i < kServoPowerSingleCount && combined.consistent; ++i) {
    if (block[kServoPowerSingleIndices[i]] != singles[i]) {
      combined.consistent = false;
    }
  }
  combined.readback = decodeServoPowerReadback(combined.consistent, block);
  combined.verdict = judgeServoPower(combined.readback);
  combined.writeBaseValid = singlesOk;
  if (singlesOk) {
    for (std::size_t i = 0; i < kPy32GpioRegisterCount; ++i) {
      combined.writeBase[i] = blockOk ? block[i] : 0;
    }
    for (std::size_t i = 0; i < kServoPowerSingleCount; ++i) {
      combined.writeBase[kServoPowerSingleIndices[i]] = singles[i];
    }
  }
  return combined;
}

inline const char* servoPowerVerdictName(ServoPowerVerdict verdict) {
  switch (verdict) {
    case ServoPowerVerdict::Off:
      return "off";
    case ServoPowerVerdict::ReadFailed:
      return "read-failed";
    case ServoPowerVerdict::OutputHigh:
      return "output-high";
    case ServoPowerVerdict::NotOutput:
      return "not-output";
    case ServoPowerVerdict::PullNotDown:
      return "pull-not-down";
  }
  return "unknown";
}

}  // namespace pet
```

- [ ] **Step 3: 通ることを確かめる**

```bash
scripts/check-core.sh 2>&1 | tail -12; echo "exit=${PIPESTATUS[0]}"
```

Expected: `servo_power_check_tests: ok`、`exit=0`。

- [ ] **Step 4: Commit**

```bash
git add firmware/core/servo_power_check.hpp tests/cpp/servo_power_check_tests.cpp scripts/check-core.sh
git status --porcelain
git commit -m "Judge the PY32 servo-power read-back on the host"
```

- [ ] **Step 5: 判定が効いていることを確かめる（変異、commit の後）**

Task 3 Step 5 と同じ手順。`readback.valid = readOk;` を `= true;`（`testFailedReadIsNeverOff`）、`readback.pu = word(6);` を `word(4)`（`testRegisterOrderDecoding`）、`(readback.pd & kServoPowerPinMask) == 0` を `false`（`testEachFaultCondition`）、`(readback.mode & kServoPowerPinMask) == 0` を `false`（同）、`if (block[kServoPowerSingleIndices[i]] != singles[i]) {` を `if (false) {`（`testCombinedOffNeedsAgreement`）、`combined.writeBase[kServoPowerSingleIndices[i]] = singles[i];` を削る（`testWriteBaseComesFromSingleReads`）、`combined.writeBaseValid = singlesOk;` を `= blockOk;`（同）、`combined.consistent = blockOk && singlesOk;` を `= blockOk;`（`testCombinedOffNeedsAgreement`）。計画作成時に全部が落ちることを確認済み。

---

### Task 7: 顔の姿勢と文の折り返し

**Files:**
- Create: `firmware/core/face_pose.hpp`, `firmware/core/text_layout.hpp`
- Test: `tests/cpp/render_logic_tests.cpp`
- Modify: `scripts/check-core.sh`

**Interfaces:**
- Consumes: Task 5 の `DisplayModel`、Task 3 の `utf8SequenceLength`
- Produces（`namespace pet`）:
  - `enum class FaceExpression : std::uint8_t { Neutral, Calm, Busy, Puzzled, Happy, Troubled }`（未接続 / idle / working / waiting / success / error）
  - `struct FacePose { FaceExpression expression; bool eyesClosed; std::int32_t gazeX; std::int32_t bounceY; }`（`==` / `!=` あり。描画のやり直し判定に使う）
  - `FaceExpression expressionFor(const DisplayModel&)`、`std::int32_t celebrateOffset(const DisplayModel&, std::uint32_t nowMs)`、`FacePose facePoseAt(const DisplayModel&, std::uint32_t nowMs)`
  - 定数: 跳ねる 600 ms・頂点 16 px（参照座標）、idle のまばたき 5 秒ごと、working のまばたき 1.8 秒ごと、閉じる 150 ms、working の目線 750 ms ごとに −6 / 0 / +6 / 0
  - `struct LineSpan { std::size_t offset, length; }`、`template <class Measure> std::size_t layoutLines(const std::uint8_t* text, std::size_t length, std::int32_t maxWidth, std::size_t maxLines, Measure measure, LineSpan* lines)`
- 表情の対応（spec §3.2）: idle=穏やか（白い丸目・平らな口・ときどきまばたき）、working=まばたき多め・目線が動く（短い口）、waiting=眉を上げ「?」、success=笑顔（工場 Happy の目＋上向きの口）、error=困り顔（工場 Sad の目＋下向きの口）、未接続=ニュートラル（灰色・静止）。spec は数値を決めていないので上の定数は本計画の決定（Deviations に記録）。

- [ ] **Step 1: 失敗するテストを書く**

`tests/cpp/render_logic_tests.cpp`:

```cpp
// Host tests for face_pose.hpp and text_layout.hpp.
#include "face_pose.hpp"
#include "text_layout.hpp"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <set>

namespace {

int failures = 0;

#define CHECK(condition)                                                      \
  do {                                                                        \
    if (!(condition)) {                                                       \
      std::fprintf(stderr, "%s:%d: CHECK(%s) failed\n", __FILE__, __LINE__, \
                   #condition);                                              \
      ++failures;                                                             \
    }                                                                         \
  } while (false)

using pet::FaceExpression;
using pet::PetState;

pet::DisplayModel connectedModel(PetState state) {
  pet::DisplayModel model{};
  model.connected = true;
  model.state = state;
  return model;
}

void testExpressionPerState() {
  pet::DisplayModel neutral{};
  neutral.state = PetState::Success;  // ignored while not connected
  CHECK(pet::expressionFor(neutral) == FaceExpression::Neutral);
  CHECK(pet::expressionFor(connectedModel(PetState::Idle)) == FaceExpression::Calm);
  CHECK(pet::expressionFor(connectedModel(PetState::Working)) == FaceExpression::Busy);
  CHECK(pet::expressionFor(connectedModel(PetState::Waiting)) == FaceExpression::Puzzled);
  CHECK(pet::expressionFor(connectedModel(PetState::Success)) == FaceExpression::Happy);
  CHECK(pet::expressionFor(connectedModel(PetState::Error)) == FaceExpression::Troubled);
}

void testCelebrateBouncesOnce() {
  auto model = connectedModel(PetState::Success);
  CHECK(pet::facePoseAt(model, 100).bounceY == 0);  // never celebrated
  model.celebrateGeneration = 1;
  model.celebrateAtMs = 1000;
  CHECK(pet::facePoseAt(model, 1000).bounceY == 0);
  CHECK(pet::facePoseAt(model, 1150).bounceY < 0);
  CHECK(pet::facePoseAt(model, 1300).bounceY == -pet::kCelebrateHeight);
  CHECK(pet::facePoseAt(model, 1450).bounceY < 0);
  CHECK(pet::facePoseAt(model, 1600).bounceY == 0);
  CHECK(pet::facePoseAt(model, 1650).bounceY == 0);
  CHECK(pet::facePoseAt(model, 9000).bounceY == 0);
  // Across the millis() wrap.
  model.celebrateAtMs = 0xFFFFFFFFu - 100u;
  CHECK(pet::facePoseAt(model, 199u).bounceY == -pet::kCelebrateHeight);
  // Disconnected faces never bounce.
  model.connected = false;
  CHECK(pet::facePoseAt(model, 199u).bounceY == 0);
}

void testBusyMovesAndNeutralIsStatic() {
  const auto busy = connectedModel(PetState::Working);
  std::set<int> gaze;
  bool sawClosed = false;
  bool sawOpen = false;
  for (std::uint32_t at = 0; at < 6000; at += 50) {
    const auto pose = pet::facePoseAt(busy, at);
    gaze.insert(pose.gazeX);
    sawClosed = sawClosed || pose.eyesClosed;
    sawOpen = sawOpen || !pose.eyesClosed;
  }
  CHECK((gaze == std::set<int>{-pet::kGazeOffset, 0, pet::kGazeOffset}));
  CHECK(sawClosed && sawOpen);

  const pet::DisplayModel neutral{};
  const auto first = pet::facePoseAt(neutral, 0);
  for (std::uint32_t at = 0; at < 12000; at += 50) {
    CHECK(pet::facePoseAt(neutral, at) == first);
  }
  CHECK(!first.eyesClosed && first.gazeX == 0);
}

// One pixel per byte keeps the expected spans easy to read.
std::int32_t bytesWide(const std::uint8_t*, std::size_t length) {
  return static_cast<std::int32_t>(length);
}

void testLayoutBreaksOnCodePoints() {
  // "aあb" + "いう": a(1) あ(3) b(1) い(3) う(3) = 11 bytes.
  const std::uint8_t text[] = {'a', 0xe3, 0x81, 0x82, 'b',
                               0xe3, 0x81, 0x84, 0xe3, 0x81, 0x86};
  pet::LineSpan lines[3];
  const std::size_t count =
      pet::layoutLines(text, sizeof(text), 5, 3, bytesWide, lines);
  CHECK(count == 3);
  CHECK(lines[0].offset == 0 && lines[0].length == 5);  // a あ b
  CHECK(lines[1].offset == 5 && lines[1].length == 3);  // い
  CHECK(lines[2].offset == 8 && lines[2].length == 3);  // う
}

void testLayoutCutsAtMaxLines() {
  const std::uint8_t text[] = {0xe3, 0x81, 0x82, 0xe3, 0x81, 0x84,
                               0xe3, 0x81, 0x86};  // あいう
  pet::LineSpan lines[2];
  const std::size_t count =
      pet::layoutLines(text, sizeof(text), 3, 2, bytesWide, lines);
  CHECK(count == 2);
  CHECK(lines[1].offset == 3 && lines[1].length == 3);
  // Nothing past the last line, and no line ends inside a code point.
  CHECK(lines[1].offset + lines[1].length == 6);
}

void testLayoutWideGlyphStillAdvances() {
  const std::uint8_t text[] = {0xf0, 0x9f, 0x98, 0x80, 'a'};  // emoji, a
  pet::LineSpan lines[3];
  const std::size_t count =
      pet::layoutLines(text, sizeof(text), 2, 3, bytesWide, lines);
  CHECK(count == 2);
  CHECK(lines[0].length == 4);
  CHECK(lines[1].offset == 4 && lines[1].length == 1);
}

void testLayoutEmptyText() {
  pet::LineSpan lines[3];
  CHECK(pet::layoutLines(nullptr, 0, 100, 3, bytesWide, lines) == 0);
}

}  // namespace

int main() {
  testExpressionPerState();
  testCelebrateBouncesOnce();
  testBusyMovesAndNeutralIsStatic();
  testLayoutBreaksOnCodePoints();
  testLayoutCutsAtMaxLines();
  testLayoutWideGlyphStillAdvances();
  testLayoutEmptyText();
  if (failures != 0) {
    std::fprintf(stderr, "render_logic_tests: %d failure(s)\n", failures);
    return 1;
  }
  std::puts("render_logic_tests: ok");
  return 0;
}
```

`scripts/check-core.sh` の `run_test servo_power_check_tests` の次に足す:

```bash
run_test render_logic_tests
```

```bash
scripts/check-core.sh 2>&1 | tail -4; echo "exit=${PIPESTATUS[0]}"
```

Expected: `fatal error: 'face_pose.hpp' file not found`、`exit=1`。

- [ ] **Step 2: 実装する**

`firmware/core/face_pose.hpp`:

```cpp
#pragma once

#include "pet_display_model.hpp"

#include <cstdint>

namespace pet {

// Which face to draw (spec 3.2). Geometry lives in FaceRenderer.
enum class FaceExpression : std::uint8_t {
  Neutral,   // not connected: static, grey
  Calm,      // idle
  Busy,      // working: frequent blinks, wandering gaze
  Puzzled,   // waiting: raised brows and "?"
  Happy,     // success
  Troubled,  // error
};

constexpr std::uint32_t kCelebrateDurationMs = 600;
constexpr std::int32_t kCelebrateHeight = 16;  // reference pixels at the peak
constexpr std::uint32_t kCalmBlinkPeriodMs = 5000;
constexpr std::uint32_t kBusyBlinkPeriodMs = 1800;
constexpr std::uint32_t kBlinkClosedMs = 150;
constexpr std::uint32_t kGazeStepMs = 750;
constexpr std::int32_t kGazeOffset = 6;

struct FacePose {
  FaceExpression expression = FaceExpression::Neutral;
  bool eyesClosed = false;
  std::int32_t gazeX = 0;    // reference pixels, + = right
  std::int32_t bounceY = 0;  // reference pixels, negative = up

  bool operator==(const FacePose& other) const {
    return expression == other.expression && eyesClosed == other.eyesClosed &&
           gazeX == other.gazeX && bounceY == other.bounceY;
  }
  bool operator!=(const FacePose& other) const { return !(*this == other); }
};

inline FaceExpression expressionFor(const DisplayModel& model) {
  if (!model.connected) {
    return FaceExpression::Neutral;
  }
  switch (model.state) {
    case PetState::Idle:
      return FaceExpression::Calm;
    case PetState::Working:
      return FaceExpression::Busy;
    case PetState::Waiting:
      return FaceExpression::Puzzled;
    case PetState::Success:
      return FaceExpression::Happy;
    case PetState::Error:
      return FaceExpression::Troubled;
  }
  return FaceExpression::Neutral;
}

// One up-and-down of the face, triangular, kCelebrateDurationMs long.
inline std::int32_t celebrateOffset(const DisplayModel& model,
                                    std::uint32_t nowMs) {
  if (model.celebrateGeneration == 0) {
    return 0;
  }
  const std::uint32_t elapsed =
      static_cast<std::uint32_t>(nowMs - model.celebrateAtMs);
  if (elapsed >= kCelebrateDurationMs) {
    return 0;
  }
  const std::uint32_t half = kCelebrateDurationMs / 2;
  const std::uint32_t rise = elapsed < half ? elapsed : kCelebrateDurationMs - elapsed;
  return -static_cast<std::int32_t>(
      (rise * static_cast<std::uint32_t>(kCelebrateHeight)) / half);
}

inline FacePose facePoseAt(const DisplayModel& model, std::uint32_t nowMs) {
  FacePose pose{};
  pose.expression = expressionFor(model);
  if (pose.expression == FaceExpression::Calm) {
    pose.eyesClosed = nowMs % kCalmBlinkPeriodMs < kBlinkClosedMs;
  } else if (pose.expression == FaceExpression::Busy) {
    pose.eyesClosed = nowMs % kBusyBlinkPeriodMs < kBlinkClosedMs;
    static constexpr std::int32_t kGaze[4] = {-kGazeOffset, 0, kGazeOffset, 0};
    pose.gazeX = kGaze[(nowMs / kGazeStepMs) % 4];
  }
  if (model.connected) {
    pose.bounceY = celebrateOffset(model, nowMs);
  }
  return pose;
}

}  // namespace pet
```

`firmware/core/text_layout.hpp`:

```cpp
#pragma once

#include "utf8.hpp"

#include <cstddef>
#include <cstdint>

namespace pet {

struct LineSpan {
  std::size_t offset = 0;
  std::size_t length = 0;
};

// Greedy line breaking on code point boundaries. `measure(bytes, length)`
// returns the drawn width in pixels. Text that does not fit in `maxLines`
// lines is cut at a code point boundary (spec 3.2). A single code point wider
// than `maxWidth` still takes a line of its own, so the loop always advances.
// Stops at the first malformed sequence (cannot happen for accepted records).
template <typename Measure>
std::size_t layoutLines(const std::uint8_t* text, std::size_t length,
                        std::int32_t maxWidth, std::size_t maxLines,
                        Measure measure, LineSpan* lines) {
  std::size_t lineCount = 0;
  std::size_t offset = 0;
  while (offset < length && lineCount < maxLines) {
    std::size_t end = offset;
    while (end < length) {
      const std::size_t step = utf8SequenceLength(text + end, length - end);
      if (step == 0) {
        length = end;  // malformed tail: draw nothing past here
        break;
      }
      if (end > offset && measure(text + offset, end + step - offset) > maxWidth) {
        break;
      }
      end += step;
    }
    if (end == offset) {
      break;
    }
    lines[lineCount].offset = offset;
    lines[lineCount].length = end - offset;
    ++lineCount;
    offset = end;
  }
  return lineCount;
}

}  // namespace pet
```

- [ ] **Step 3: 通ることを確かめる**

```bash
scripts/check-core.sh 2>&1 | tail -14; echo "exit=${PIPESTATUS[0]}"
```

Expected: `render_logic_tests: ok`、`exit=0`。

- [ ] **Step 4: Commit**

```bash
git add firmware/core/face_pose.hpp firmware/core/text_layout.hpp tests/cpp/render_logic_tests.cpp scripts/check-core.sh
git status --porcelain
git commit -m "Pick the face pose and wrap the subtitle on code point boundaries"
```

- [ ] **Step 5: 判定が効いていることを確かめる（変異、commit の後）**

Task 3 Step 5 と同じ手順。`if (elapsed >= kCelebrateDurationMs)` を `if (elapsed > kCelebrateDurationMs + 100)`（1650 ms の検査で落ちる）、`if (model.connected) {` を `if (true) {`（未接続は跳ねない）、`end > offset && measure` を `end >= offset && measure`（幅の広い 1 文字でも進む）。計画作成時に全部が落ちることを確認済み。

---

### Task 8: SafeBoard とプローブのビルド、ELF 検査

**Files:**
- Create: `firmware/StackChanPet/SafeBoard.h`, `firmware/StackChanPet/SafeBoard.cpp`
- Create: `firmware/StackChanPet/StackChanPet.ino`（この時点では SafeBoard だけ。Task 9 で置き換える）
- Create: `scripts/check-elf-safety.sh`

**Interfaces:**
- Consumes: Task 2 の BSP API、Task 6 の `decodeServoPowerReadback` / `judgeServoPower`
- Produces:
  - `struct BoardNotice { bool servoPowerUnverified; pet::ServoPowerVerdict verdict; std::uint32_t rewriteCount; std::uint32_t readFailureCount; std::uint32_t mismatchCount; bool powerMonitorFailed; bool bleFailed; }`（`==` / `!=` あり。`readFailureCount` は I2C の読み取り自体の失敗、`mismatchCount` は読めたがまとめ読みと単独読みが食い違った回数）
  - `class SafeBoard { void begin(bool probeScreen); void poll(std::uint32_t nowMs); const BoardNotice& notice() const; void setBleFailed(bool); }`
  - シリアル行の形式（Task 10・11 の記録が読む）: `SAFE <phase> t=<ms> found=<0|1> block=<0|1> M=<H><L> O=<H><L> I=<H><L> PU=<H><L> PD=<H><L> single=<ok>:<M_L>,<O_L>,<PU_L>,<PD_L> consistent=<0|1> verdict=<name> ack=<-1|0|1> rewrites=<n> readfail=<n> mismatch=<n> ina226=<0|1>`。phase は `BOOT-READ`（書く前。以後 1 秒ごとに、その秒の最初の行として再掲）、`BOOT-OFF`、`CHECK`、`CHECK-READ-FAILED`、`CHECK-CHANGED`、`CHECK-REWRITE`
- 起動手順（spec §3.4）: `M5.begin()` → `waitForIoExpander()`（200 ms 間隔・最大約 1.2 秒）→ **何も書く前に** まとめ読みと単独読みを記録 → `forceServoPowerOff`（書き順は Task 2）→ 読み戻しで判定 → INA226 の初期化（失敗は `powerMonitorFailed`、サーボの fault とは別）→ 以後 1 秒ごとに読み戻し、OFF でなければ `rewriteCount` を増やして書き直し、再度読み戻す。
- まとめ読みと単独読みの照合・判定・書く値の元は Task 6 の `pet::combineReadback`（ホストでテスト済み）。SafeBoard は I2C で読んで渡すだけで、BSP と core のレジスタ番号・位置が一致することを `static_assert` で固定する。食い違えば fault 表示になり（`mismatch` が増える）、Task 10 で止まって報告する。

- [ ] **Step 1: 失敗する ELF 検査を書き、反例（PoC の ELF）で落ちることを確かめる**

`scripts/check-elf-safety.sh`:

```bash
#!/usr/bin/env bash
# Spec 3.4: the linked firmware must not contain any path that can turn servo
# power on or drive the servos.
#   check-elf-safety.sh <firmware.elf>
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLCHAIN_DIR="${STACKCHAN_TOOLCHAIN_DIR:-$ROOT_DIR/.cache}"
ELF="${1:?usage: $0 <firmware.elf>}"

fail() {
  echo "check-elf-safety: $*" >&2
  exit 1
}

shopt -s nullglob
nm_candidates=("$TOOLCHAIN_DIR"/arduino/data/packages/esp32/tools/esp-x32/*/bin/xtensa-esp32s3-elf-nm)
shopt -u nullglob
[[ ${#nm_candidates[@]} -eq 1 ]] || fail "expected exactly one xtensa-esp32s3-elf-nm, found ${#nm_candidates[@]}"
NM="${nm_candidates[0]}"
[[ -f "$ELF" ]] || fail "missing ELF: $ELF"

symbols="$("$NM" -C "$ELF")"
symbol_count="$(printf '%s\n' "$symbols" | wc -l | tr -d ' ')"
[[ "$symbol_count" -gt 1000 ]] || fail "only $symbol_count symbols; wrong file or stripped ELF"

FORBIDDEN='M5StackChan_Class::begin\(|M5StackChan_Class::beginSafeBoard|servo_init|SCSCL|SMS_STS|HLSCL|SCServo|ScsServo|stackchan::motion|(^|[^A-Za-z_])Motion([^A-Za-z_]|$)|setServoPowerEnabled|io_expander_init|PY32IOExpander_Class'
hits="$(printf '%s\n' "$symbols" | grep -E "$FORBIDDEN" || true)"
if [[ -n "$hits" ]]; then
  printf '%s\n' "$hits" >&2
  fail "forbidden servo-power / servo-drive symbols present"
fi

# The check must be looking at this firmware: its OFF path has to be linked.
printf '%s\n' "$symbols" | grep -q 'M5StackChan_Class::forceServoPowerOff' ||
  fail "forceServoPowerOff not found; not a StackChanPet ELF?"
echo "check-elf-safety: ok ($symbol_count symbols)"
```

```bash
chmod +x scripts/check-elf-safety.sh
scripts/check-elf-safety.sh ~/agent-work/uwb-stackchan-poc/.cache/firmware-build/StackChanTracker.ino.elf 2>&1 | tail -6; echo "exit=${PIPESTATUS[0]}"
```

Expected: `SCSCL`・`stackchan::motion`・`setServoPowerEnabledChecked`・`PY32IOExpander_Class` などのシンボルが列挙され、`check-elf-safety: forbidden servo-power / servo-drive symbols present`、`exit=1`（計画作成時に PoC の ELF で同じ結果を確認済み）。PoC の ELF が無ければ、このステップは「反例が無いので未確認」と記録して進む（作り直さない）。

- [ ] **Step 2: SafeBoard とプローブのスケッチを書く**

`firmware/StackChanPet/SafeBoard.h`:

```cpp
#pragma once

#include "servo_power_check.hpp"

#include <M5StackChan.h>

#include <cstdint>

// What the screen must show about the board (spec 3.4).
struct BoardNotice {
  // true: show "SERVO OFF 未確認" instead of the face.
  bool servoPowerUnverified = true;
  pet::ServoPowerVerdict verdict = pet::ServoPowerVerdict::ReadFailed;
  std::uint32_t rewriteCount = 0;      // OFF written again after boot
  std::uint32_t readFailureCount = 0;  // checks whose I2C reads failed
  std::uint32_t mismatchCount = 0;     // reads succeeded, block != singles
  bool powerMonitorFailed = false;     // INA226; a separate, milder notice
  bool bleFailed = false;

  bool operator==(const BoardNotice& other) const {
    return servoPowerUnverified == other.servoPowerUnverified &&
           verdict == other.verdict && rewriteCount == other.rewriteCount &&
           readFailureCount == other.readFailureCount &&
           mismatchCount == other.mismatchCount &&
           powerMonitorFailed == other.powerMonitorFailed &&
           bleFailed == other.bleFailed;
  }
  bool operator!=(const BoardNotice& other) const { return !(*this == other); }
};

class SafeBoard {
 public:
  // M5.begin(), wait for the PY32, read its GPIO block before writing
  // anything, write OFF in the spec order, verify by reading back.
  // `probeScreen` keeps the boot readings on screen (SafeBoard probe build).
  void begin(bool probeScreen);
  // Once per second: read back; if it is no longer OFF, write OFF again,
  // count it and verify again.
  void poll(std::uint32_t nowMs);

  const BoardNotice& notice() const { return notice_; }
  void setBleFailed(bool failed) { notice_.bleFailed = failed; }

 private:
  struct Snapshot {
    m5::ServoPowerRaw block{};  // bulk read 0x03..0x0C
    std::uint8_t singles[pet::kServoPowerSingleCount] = {};  // read one by one
    bool singlesOk = false;
    pet::CombinedReadback combined{};  // core: agreement, verdict, write base
    m5::ServoPowerRaw writeBase{};     // combined.writeBase for the BSP call
    bool consistent = false;
    pet::ServoPowerVerdict verdict = pet::ServoPowerVerdict::ReadFailed;
  };

  Snapshot readSnapshot();
  void writeOffAndVerify(const Snapshot& before, const char* phase);
  void apply(const Snapshot& after);
  void log(const char* phase, const Snapshot& snapshot, int writeAck);
  void drawProbeScreen();

  BoardNotice notice_{};
  Snapshot boot_{};
  Snapshot last_{};
  bool ioExpanderFound_ = false;
  bool probeScreen_ = false;
  std::uint32_t nextCheckMs_ = 0;
};
```

`firmware/StackChanPet/SafeBoard.cpp`:

```cpp
#include "SafeBoard.h"

#include <M5Unified.h>

#include <cstdio>

namespace {

constexpr std::uint32_t kRecheckPeriodMs = 1000;

// The single-register cross-check and the verdict are core functions
// (servo_power_check.hpp, host-tested); this file only does the I2C.
static_assert(m5::py32::kGpioBlockLength == pet::kPy32GpioRegisterCount,
              "BSP block and core decoder must agree on the block length");
static_assert(m5::py32::REG_GPIO_M_L == pet::kPy32FirstGpioRegister,
              "BSP block and core decoder must agree on the first register");
static_assert(m5::py32::REG_GPIO_M_L == pet::kServoPowerSingleRegisters[0] &&
                  m5::py32::REG_GPIO_O_L == pet::kServoPowerSingleRegisters[1] &&
                  m5::py32::REG_GPIO_PU_L == pet::kServoPowerSingleRegisters[2] &&
                  m5::py32::REG_GPIO_PD_L == pet::kServoPowerSingleRegisters[3],
              "BSP register map and core single-register list must agree");
static_assert(m5::py32::kIndexModeLow == pet::kServoPowerSingleIndices[0] &&
                  m5::py32::kIndexOutputLow == pet::kServoPowerSingleIndices[1] &&
                  m5::py32::kIndexPullUpLow == pet::kServoPowerSingleIndices[2] &&
                  m5::py32::kIndexPullDownLow == pet::kServoPowerSingleIndices[3],
              "BSP block indices and core single-register indices must agree");

bool serialReady() { return Serial.availableForWrite() > 200; }

}  // namespace

SafeBoard::Snapshot SafeBoard::readSnapshot() {
  Snapshot s{};
  s.block = M5StackChan.readServoPowerConfig();
  s.singlesOk = true;
  for (std::size_t i = 0; i < pet::kServoPowerSingleCount; ++i) {
    const bool ok = M5StackChan.readIoExpanderByte(
        pet::kServoPowerSingleRegisters[i], &s.singles[i]);
    s.singlesOk = s.singlesOk && ok;
  }
  s.combined = pet::combineReadback(s.block.valid, s.block.reg, s.singlesOk,
                                    s.singles);
  s.consistent = s.combined.consistent;
  s.verdict = s.combined.verdict;
  s.writeBase.valid = s.combined.writeBaseValid;
  for (std::size_t i = 0; i < pet::kPy32GpioRegisterCount; ++i) {
    s.writeBase.reg[i] = s.combined.writeBase[i];
  }
  return s;
}

void SafeBoard::begin(bool probeScreen) {
  probeScreen_ = probeScreen;
  auto config = M5.config();
  M5.begin(config);

  ioExpanderFound_ = M5StackChan.waitForIoExpander();
  // Spec 3.4 step 2: read before anything is written.
  boot_ = readSnapshot();
  log("BOOT-READ", boot_, -1);
  writeOffAndVerify(boot_, "BOOT-OFF");
  notice_.powerMonitorFailed = !M5StackChan.beginPowerMonitor();
  drawProbeScreen();
  nextCheckMs_ = millis() + kRecheckPeriodMs;
}

void SafeBoard::writeOffAndVerify(const Snapshot& before, const char* phase) {
  int ack = -1;  // -1: nothing written (no successful read to build on)
  if (before.writeBase.valid) {
    ack = M5StackChan.forceServoPowerOff(before.writeBase) ? 1 : 0;
  }
  const Snapshot after = readSnapshot();
  apply(after);
  log(phase, after, ack);
}

void SafeBoard::apply(const Snapshot& after) {
  last_ = after;
  notice_.verdict = after.verdict;
  notice_.servoPowerUnverified = after.verdict != pet::ServoPowerVerdict::Off;
  if (!after.block.valid || !after.singlesOk) {
    ++notice_.readFailureCount;
  } else if (!after.consistent) {
    ++notice_.mismatchCount;  // judged ReadFailed, but the bus worked
  }
}

void SafeBoard::poll(std::uint32_t nowMs) {
  if (static_cast<std::int32_t>(nowMs - nextCheckMs_) < 0) {
    return;
  }
  nextCheckMs_ = nowMs + kRecheckPeriodMs;
  // Repeat the boot reading first, so a serial capture started late still
  // gets it even if the TX buffer fills.
  log("BOOT-READ", boot_, -1);
  const Snapshot now = readSnapshot();
  if (now.verdict == pet::ServoPowerVerdict::Off) {
    apply(now);
    log("CHECK", now, -1);
  } else if (!now.writeBase.valid) {
    apply(now);  // nothing to build a write on; stays a fault
    log("CHECK-READ-FAILED", now, -1);
  } else {
    // Changed since the last check (PY32 reset, or the block read disagrees).
    ++notice_.rewriteCount;
    log("CHECK-CHANGED", now, -1);
    writeOffAndVerify(now, "CHECK-REWRITE");
  }
  if (probeScreen_) {
    drawProbeScreen();
  }
}

void SafeBoard::log(const char* phase, const Snapshot& s, int writeAck) {
  if (!serialReady()) {
    return;
  }
  const std::uint8_t* r = s.block.reg;
  Serial.printf(
      "SAFE %s t=%lu found=%u block=%u M=%02X%02X O=%02X%02X I=%02X%02X "
      "PU=%02X%02X PD=%02X%02X single=%u:%02X,%02X,%02X,%02X consistent=%u "
      "verdict=%s ack=%d rewrites=%lu readfail=%lu mismatch=%lu ina226=%u\n",
      phase, static_cast<unsigned long>(millis()), ioExpanderFound_ ? 1u : 0u,
      s.block.valid ? 1u : 0u, r[1], r[0], r[3], r[2], r[5], r[4], r[7], r[6],
      r[9], r[8], s.singlesOk ? 1u : 0u, s.singles[0], s.singles[1],
      s.singles[2], s.singles[3], s.consistent ? 1u : 0u,
      pet::servoPowerVerdictName(s.verdict), writeAck,
      static_cast<unsigned long>(notice_.rewriteCount),
      static_cast<unsigned long>(notice_.readFailureCount),
      static_cast<unsigned long>(notice_.mismatchCount),
      notice_.powerMonitorFailed ? 0u : 1u);
}

void SafeBoard::drawProbeScreen() {
  auto& display = M5.Display;
  display.startWrite();
  display.fillScreen(TFT_BLACK);
  display.setFont(&fonts::Font2);
  display.setTextSize(1);
  display.setTextColor(TFT_WHITE, TFT_BLACK);
  char line[96];
  std::int32_t y = 4;
  const std::int32_t step = display.fontHeight() + 4;
  const auto put = [&](const char* text) {
    display.drawString(text, 4, y);
    y += step;
  };
  const std::uint8_t* b = boot_.block.reg;
  put("SafeBoard (BOOT = before any write)");
  std::snprintf(line, sizeof(line), "PY32 found=%u block=%u single=%u",
                ioExpanderFound_ ? 1u : 0u, boot_.block.valid ? 1u : 0u,
                boot_.singlesOk ? 1u : 0u);
  put(line);
  std::snprintf(line, sizeof(line), "BOOT M=%02X O=%02X PU=%02X PD=%02X",
                b[0], b[2], b[6], b[8]);
  put(line);
  std::snprintf(line, sizeof(line), "BOOT verdict=%s",
                pet::servoPowerVerdictName(boot_.verdict));
  put(line);
  const std::uint8_t* n = last_.block.reg;
  std::snprintf(line, sizeof(line), "NOW  M=%02X O=%02X PU=%02X PD=%02X",
                n[0], n[2], n[6], n[8]);
  put(line);
  std::snprintf(line, sizeof(line), "NOW  verdict=%s t=%lus",
                pet::servoPowerVerdictName(last_.verdict),
                static_cast<unsigned long>(millis() / 1000));
  put(line);
  std::snprintf(line, sizeof(line), "rewrites=%lu readfail=%lu mismatch=%lu ina226=%u",
                static_cast<unsigned long>(notice_.rewriteCount),
                static_cast<unsigned long>(notice_.readFailureCount),
                static_cast<unsigned long>(notice_.mismatchCount),
                notice_.powerMonitorFailed ? 0u : 1u);
  put(line);
  display.endWrite();
}
```

`firmware/StackChanPet/StackChanPet.ino`（Task 9 で置き換える）:

```cpp
// SafeBoard only (Task 8). Task 9 replaces this file with the full sketch.
#include <M5StackChan.h>
#include <M5Unified.h>

#include "SafeBoard.h"

namespace {
SafeBoard safeBoard;
}

// The default 256-byte USB CDC TX ring cannot hold one burst of SAFE lines.
constexpr size_t kSerialTxBufferBytes = 4096;

void setup() {
  Serial.setTxBufferSize(kSerialTxBufferBytes);
  Serial.begin(115200);
  safeBoard.begin(true);
}

void loop() {
  M5.update();
  safeBoard.poll(millis());
  delay(1);
}
```

- [ ] **Step 3: プローブをビルドする**

```bash
scripts/build-firmware.sh --probe; echo "exit=$?"
```

Expected: arduino-cli の末尾に `Used library ... StackChan-BSP 1.1.0 .../vendor/StackChan-BSP`、`M5Unified 0.2.25`、`M5GFX 0.2.32`、`StackChanPetCore 1.0.0`、`Used platform esp32:esp32 3.3.11`。続いて `factory_nvs: offset=0x9000 size=0x4000 readonly` と `application: offset=0x010000`、最後に `check-elf-safety: ok (<n> symbols)`、`exit=0`。

コンパイルエラーは、BSP / M5Unified / M5GFX のヘッダ（`.cache/arduino/user/libraries/...`）を読んで直す。直し方は保守側を選び（安全確認を弱めない、書き込みを増やさない）、変えた点を implementation-notes の Deviations に書く。`check-servo-writes.sh` を必ず再実行する。

```bash
NM=$(ls .cache/arduino/data/packages/esp32/tools/esp-x32/*/bin/xtensa-esp32s3-elf-nm)
"$NM" -C .cache/firmware-build-probe/StackChanPet.ino.elf | grep -c 'BLEServer::' ; echo "grep-exit=$?"
scripts/check-core.sh 2>&1 | tail -3; echo "exit=${PIPESTATUS[0]}"
```

Expected: プローブの ELF に `BLEServer::` は 0 件（`grep-exit=1`）。`check-core.sh` は `exit=0`。

- [ ] **Step 4: Commit**

```bash
git add firmware/StackChanPet/SafeBoard.h firmware/StackChanPet/SafeBoard.cpp firmware/StackChanPet/StackChanPet.ino scripts/check-elf-safety.sh
git status --porcelain
git commit -m "Verify servo power off by read-back at boot and every second"
```

---

### Task 9: BLE、描画、メインループ

**Files:**
- Create: `firmware/StackChanPet/PetPeripheral.h`, `firmware/StackChanPet/PetPeripheral.cpp`
- Create: `firmware/StackChanPet/FaceRenderer.h`, `firmware/StackChanPet/FaceRenderer.cpp`
- Create: `firmware/StackChanPet/RecordIntake.h`（Task 5 の `pet::toModelEvent` に Serial のログを足す薄い包み。`.ino` に関数を置くと Arduino のプロトタイプ生成が壊しうるのでヘッダにする）
- Replace: `firmware/StackChanPet/StackChanPet.ino`
- Create: `scripts/capture-serial.py`

**Interfaces:**
- Consumes: Task 5 の `PetMailbox` / `PetDisplayModel`、Task 7 の `facePoseAt` / `layoutLines`、Task 8 の `SafeBoard` / `BoardNotice`
- Produces:
  - `class PetPeripheral : BLEServerCallbacks { bool begin(); bool take(pet::PetMailbox::Item&); }`。`onConnect` / `onDisconnect` / `onWrite` は portMUX のクリティカルセクションで mailbox を触るだけ
  - `class PetRenderer { virtual void render(const pet::DisplayModel&, const BoardNotice&, std::uint32_t nowMs) = 0; }`（スプライト表示への差し替え境界）、`class FaceRenderer : PetRenderer { void begin(LGFX_Device&); }`
  - 画面割り（320×240）: 上 170 px が顔（PSRAM の `M5Canvas` に描いて転送。確保できなければ直接描く）、172 px から状態語（`efontJA_10` を `setTextSize(2)`）、200 px から文（`efontJA_10`、最大 3 行）。サーボの fault は上 170 px を赤にして「SERVO OFF 未確認」と判定名・回数を出す（顔の代わり。状態語と文は下で更新を続ける）。INA226・BLE の初期化失敗は上端の黄色い帯で、顔は出す。OFF の書き直しが 1 回でもあれば右上に「VM再書込 n」。
  - 状態語: idle `待機中`、working `作業中`、waiting `入力待ち`、success `完了`、error `失敗`、未接続 `未接続`。**spec からの補足:** spec §1.2 は idle の語を挙げていないので `待機中` とする（Deviations）。
  - シリアル: `RX t=<ms> gen=<n> len=<n> result=<none|short|version|status|length|utf8>`、`DISCONNECT t=<ms> gen=<n>`
- 同梱 BLE の API は esp32 core 3.3.11 の `libraries/BLE/src` で確認済み: NimBLE 時の `BLEServerCallbacks::onConnect(BLEServer*, ble_gap_conn_desc*)` / `onDisconnect(...)`、`BLECharacteristicCallbacks::onWrite(BLECharacteristic*, ble_gap_conn_desc*)`、`PROPERTY_WRITE_NR = BLE_GATT_CHR_F_WRITE_NO_RSP`、`advertiseOnDisconnect(bool)`、切断時の再 advertising（`BLE_GAP_EVENT_DISCONNECT` の処理。`CONFIG_BT_NIMBLE_EXT_ADV` が未設定のときだけ動き、ESP32-S3 の sdkconfig では未設定）、`onWrite` は値を `setValue` してから同期で呼ばれる（最大 `BLE_ATT_ATTR_MAX_LEN`）。ESP32-S3 の sdkconfig は `CONFIG_BT_NIMBLE_ENABLED=y`、`CONFIG_BT_NIMBLE_MAX_CONNECTIONS=3`、`CONFIG_BT_NIMBLE_ATT_PREFERRED_MTU=256`、`BLE_ATT_ATTR_MAX_LEN` は 512。
- 未検証（Task 11 で実機確認）: 接続が成立すると advertising が止まり、2 台目から見えなくなること（単一接続の前提。コード上は接続時に advertising を再開する処理が無いことだけを確認済み）。

- [ ] **Step 1: 部品を書く**

`firmware/StackChanPet/PetPeripheral.h`:

```cpp
#pragma once

#include "pet_mailbox.hpp"

#include <BLECharacteristic.h>
#include <BLEDevice.h>
#include <BLEServer.h>

// GATT peripheral for wire contract v1 (spec 1.1, 3.3). Callbacks run on the
// NimBLE host task and only touch the mailbox; the main loop drains it.
class PetPeripheral final : public BLEServerCallbacks {
 public:
  PetPeripheral() : writeCallbacks_(*this) {}

  bool begin();
  // Main loop only.
  bool take(pet::PetMailbox::Item& out);

#if defined(CONFIG_NIMBLE_ENABLED)
  void onConnect(BLEServer* server, ble_gap_conn_desc* desc) override;
  void onDisconnect(BLEServer* server, ble_gap_conn_desc* desc) override;
#endif

 private:
  class WriteCallbacks final : public BLECharacteristicCallbacks {
   public:
    explicit WriteCallbacks(PetPeripheral& owner) : owner_(owner) {}
#if defined(CONFIG_NIMBLE_ENABLED)
    void onWrite(BLECharacteristic* characteristic,
                 ble_gap_conn_desc* desc) override;
#endif

   private:
    PetPeripheral& owner_;
  };

  pet::PetMailbox mailbox_;
  WriteCallbacks writeCallbacks_;
  BLEServer* server_ = nullptr;
};
```

`firmware/StackChanPet/PetPeripheral.cpp`:

```cpp
// Not part of the SafeBoard probe build (no BLE, no face).
#if !defined(PET_SAFEBOARD_PROBE)

#include "PetPeripheral.h"

#include <BLEAdvertising.h>
#include <BLEService.h>

#include <freertos/FreeRTOS.h>

#if !defined(CONFIG_NIMBLE_ENABLED)
#error "StackChanPet expects the NimBLE backend (esp32 core 3.3.11, ESP32-S3)"
#endif

namespace {

// Spec 1.1, verbatim.
constexpr char kDeviceName[] = "StackChanPet";
constexpr char kServiceUuid[] = "B405CCEA-139A-4248-9CDE-5BAB2613D855";
constexpr char kStateUuid[] = "24EE255E-42EC-4702-AF9C-C8EF325929AC";

portMUX_TYPE gMailboxMux = portMUX_INITIALIZER_UNLOCKED;

}  // namespace

bool PetPeripheral::begin() {
  if (!BLEDevice::init(kDeviceName)) {
    return false;
  }
  server_ = BLEDevice::createServer();
  if (server_ == nullptr) {
    return false;
  }
  server_->setCallbacks(this);
  // Single connection: a connection ends advertising; restart it only after
  // the peer leaves (spec 3.3).
  server_->advertiseOnDisconnect(true);

  BLEService* service = server_->createService(kServiceUuid);
  if (service == nullptr) {
    return false;
  }
  BLECharacteristic* state = service->createCharacteristic(
      kStateUuid, BLECharacteristic::PROPERTY_WRITE_NR);
  if (state == nullptr) {
    return false;
  }
  state->setCallbacks(&writeCallbacks_);
  if (!service->start()) {
    return false;
  }

  BLEAdvertising* advertising = server_->getAdvertising();
  if (advertising == nullptr) {
    return false;
  }
  advertising->addServiceUUID(kServiceUuid);
  advertising->setName(kDeviceName);
  advertising->setScanResponse(true);
  server_->startAdvertising();
  return true;
}

bool PetPeripheral::take(pet::PetMailbox::Item& out) {
  portENTER_CRITICAL(&gMailboxMux);
  const bool taken = mailbox_.take(out);
  portEXIT_CRITICAL(&gMailboxMux);
  return taken;
}

void PetPeripheral::onConnect(BLEServer* server, ble_gap_conn_desc* desc) {
  (void)server;
  (void)desc;
  portENTER_CRITICAL(&gMailboxMux);
  (void)mailbox_.onConnect();
  portEXIT_CRITICAL(&gMailboxMux);
}

void PetPeripheral::onDisconnect(BLEServer* server, ble_gap_conn_desc* desc) {
  (void)server;
  (void)desc;
  portENTER_CRITICAL(&gMailboxMux);
  mailbox_.onDisconnect();
  portEXIT_CRITICAL(&gMailboxMux);
}

void PetPeripheral::WriteCallbacks::onWrite(BLECharacteristic* characteristic,
                                            ble_gap_conn_desc* desc) {
  (void)desc;
  if (characteristic == nullptr) {
    return;
  }
  // Copy only; parsing and drawing happen on the main loop.
  const std::uint8_t* data = characteristic->getData();
  const std::size_t length = characteristic->getLength();
  portENTER_CRITICAL(&gMailboxMux);
  owner_.mailbox_.onWrite(data, length);
  portEXIT_CRITICAL(&gMailboxMux);
}

#endif  // !defined(PET_SAFEBOARD_PROBE)
```

`firmware/StackChanPet/FaceRenderer.h`:

```cpp
#pragma once

#include "SafeBoard.h"
#include "face_pose.hpp"
#include "pet_display_model.hpp"

#include <M5GFX.h>

#include <cstdint>

// The boundary a sprite renderer replaces later (spec 3.2): it receives the
// display model and the board notice, nothing else.
class PetRenderer {
 public:
  virtual ~PetRenderer() = default;
  virtual void render(const pet::DisplayModel& model, const BoardNotice& notice,
                      std::uint32_t nowMs) = 0;
};

class FaceRenderer final : public PetRenderer {
 public:
  void begin(LGFX_Device& display);
  void render(const pet::DisplayModel& model, const BoardNotice& notice,
              std::uint32_t nowMs) override;

 private:
  void drawUpper(lgfx::LovyanGFX& target, const pet::FacePose& pose,
                 const BoardNotice& notice);
  void drawLower(const pet::DisplayModel& model);

  LGFX_Device* display_ = nullptr;
  M5Canvas canvas_;
  bool canvasReady_ = false;
  bool drawn_ = false;
  pet::FacePose lastPose_{};
  BoardNotice lastNotice_{};
  std::uint32_t lastContentGeneration_ = 0;
};
```

`firmware/StackChanPet/FaceRenderer.cpp`（`drawFace` は PoC の `drawFace` を基にした。出所は provenance と関数のコメント）:

```cpp
// Not part of the SafeBoard probe build (no BLE, no face).
#if !defined(PET_SAFEBOARD_PROBE)

#include "FaceRenderer.h"

#include "text_layout.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>

namespace {

// 320x240 screen: face (and fault screen) above, state word and text below.
constexpr std::int32_t kUpperHeight = 170;
constexpr std::int32_t kStateTop = 172;
constexpr std::int32_t kTextTop = 200;
constexpr std::int32_t kTextLeft = 8;
constexpr std::size_t kMaxTextLines = 3;
constexpr float kPi = 3.14159265358979323846f;

const char* stateWord(const pet::DisplayModel& model) {
  if (!model.connected) {
    return "未接続";
  }
  switch (model.state) {
    case pet::PetState::Idle:
      return "待機中";
    case pet::PetState::Working:
      return "作業中";
    case pet::PetState::Waiting:
      return "入力待ち";
    case pet::PetState::Success:
      return "完了";
    case pet::PetState::Error:
      return "失敗";
  }
  return "";
}

// Face geometry adapted from the PoC drawFace (uwb-stackchan-poc
// firmware/StackChanTracker/Firmware.cpp), itself adapted from M5Stack's
// default StackChan avatar (firmware/main/stackchan/avatar/skins/default,
// m5stack/StackChan 1b5765599fba8aaad1811d9a79358ccc7051f5f3):
// Copyright (c) 2026 M5Stack Technology CO LTD, MIT licensed. Full text in
// licenses/m5stack-StackChan-firmware-LICENSE.txt. Reference canvas 320x240,
// eyes at (90,104) and (230,104), mouth at (160,146).
void drawFace(lgfx::LovyanGFX& gfx, const pet::FacePose& pose,
              std::int32_t width, std::int32_t height) {
  const float scale = std::min(static_cast<float>(width) / 320.0f,
                               static_cast<float>(height) / 120.0f);
  const float centerX = static_cast<float>(width) / 2.0f;
  const float centerY = static_cast<float>(height) / 2.0f +
                        static_cast<float>(pose.bounceY) * scale;
  // RGB565 like the PoC: LovyanGFX reads a uint32_t colour as RGB888.
  const std::uint16_t color = static_cast<std::uint16_t>(
      pose.expression == pet::FaceExpression::Neutral ? TFT_DARKGREY : TFT_WHITE);
  const float gaze = static_cast<float>(pose.gazeX);

  const auto xAt = [&](float x) {
    return static_cast<std::int32_t>(std::lround(centerX + (x - 160.0f) * scale));
  };
  const auto yAt = [&](float y) {
    return static_cast<std::int32_t>(std::lround(centerY + (y - 120.0f) * scale));
  };
  const auto sized = [&](float value) {
    return std::max<std::int32_t>(1, static_cast<std::int32_t>(std::lround(value * scale)));
  };

  // weight/rotation as in the factory DefaultEyes: Neutral 100/0,
  // Happy 72/+-155 deg, Sad 70/-+40 deg.
  const auto eye = [&](float referenceX, int weight, int rotationTenths) {
    const float cx = referenceX + gaze;
    const std::int32_t eyeX = xAt(cx);
    const std::int32_t eyeY = yAt(104.0f);
    const std::int32_t eyeSize = sized(20.0f);
    if (pose.eyesClosed) {
      gfx.fillRect(eyeX - eyeSize / 2, eyeY - sized(2.0f), eyeSize, sized(4.0f), color);
      return;
    }
    gfx.fillRoundRect(eyeX - eyeSize / 2, eyeY - eyeSize / 2, eyeSize, eyeSize,
                      eyeSize / 2, color);
    if (weight == 100 && rotationTenths == 0) {
      return;
    }
    const float eyelidCenterY = -static_cast<float>((weight * 20) / 100);
    const float angle = static_cast<float>(rotationTenths) * kPi / 1800.0f;
    const float cosine = std::cos(angle);
    const float sine = std::sin(angle);
    const std::array<std::array<float, 2>, 4> local{{
        {{-10.0f, eyelidCenterY - 10.0f}},
        {{10.0f, eyelidCenterY - 10.0f}},
        {{10.0f, eyelidCenterY + 10.0f}},
        {{-10.0f, eyelidCenterY + 10.0f}},
    }};
    std::array<std::array<std::int32_t, 2>, 4> corners{};
    for (std::size_t i = 0; i < local.size(); ++i) {
      const float rx = local[i][0] * cosine - local[i][1] * sine;
      const float ry = local[i][0] * sine + local[i][1] * cosine;
      corners[i] = {{
          static_cast<std::int32_t>(std::lround(centerX + (cx - 160.0f + rx) * scale)),
          static_cast<std::int32_t>(std::lround(centerY + (-16.0f + ry) * scale)),
      }};
    }
    gfx.fillTriangle(corners[0][0], corners[0][1], corners[1][0], corners[1][1],
                     corners[2][0], corners[2][1], TFT_BLACK);
    gfx.fillTriangle(corners[0][0], corners[0][1], corners[2][0], corners[2][1],
                     corners[3][0], corners[3][1], TFT_BLACK);
  };

  const auto flatMouth = [&](float referenceWidth) {
    const std::int32_t w = sized(referenceWidth);
    const std::int32_t h = sized(6.0f);
    gfx.fillRect(xAt(160.0f) - w / 2, yAt(146.0f) - h / 2, w, h, color);
  };

  const auto curvedMouth = [&](float direction) {
    constexpr float kWidth = 90.0f;
    constexpr float kDepth = 14.0f;
    constexpr int kSegments = 12;
    const float radius = 3.0f * scale;
    std::int32_t px = xAt(160.0f - kWidth / 2.0f);
    std::int32_t py = yAt(146.0f);
    gfx.drawSpot(px, py, radius, color);
    for (int segment = 1; segment <= kSegments; ++segment) {
      const float t = static_cast<float>(segment) / kSegments;
      const std::int32_t x = xAt(160.0f - kWidth / 2.0f + kWidth * t);
      const std::int32_t y = yAt(146.0f + direction * 4.0f * kDepth * t * (1.0f - t));
      gfx.drawWideLine(px, py, x, y, radius, color);
      gfx.drawSpot(x, y, radius, color);
      px = x;
      py = y;
    }
  };

  switch (pose.expression) {
    case pet::FaceExpression::Happy:
      eye(90.0f, 72, 1550);
      eye(230.0f, 72, -1550);
      curvedMouth(1.0f);
      break;
    case pet::FaceExpression::Troubled:
      eye(90.0f, 70, -400);
      eye(230.0f, 70, 400);
      curvedMouth(-1.0f);
      break;
    case pet::FaceExpression::Puzzled: {
      eye(90.0f, 100, 0);
      eye(230.0f, 100, 0);
      const float browRadius = std::max(1.0f, 2.5f * scale);
      gfx.drawWideLine(xAt(72.0f), yAt(82.0f), xAt(108.0f), yAt(74.0f), browRadius, color);
      gfx.drawWideLine(xAt(212.0f), yAt(74.0f), xAt(248.0f), yAt(82.0f), browRadius, color);
      gfx.setFont(&fonts::efontJA_10);
      gfx.setTextSize(std::max(1.0f, 3.0f * scale));
      gfx.setTextColor(color);
      gfx.drawString("?", xAt(262.0f), yAt(56.0f));
      flatMouth(30.0f);
      break;
    }
    case pet::FaceExpression::Busy:
      eye(90.0f, 100, 0);
      eye(230.0f, 100, 0);
      flatMouth(30.0f);
      break;
    case pet::FaceExpression::Calm:
    case pet::FaceExpression::Neutral:
      eye(90.0f, 100, 0);
      eye(230.0f, 100, 0);
      flatMouth(90.0f);
      break;
  }
}

void drawFault(lgfx::LovyanGFX& gfx, const BoardNotice& notice,
               std::int32_t width, std::int32_t height) {
  gfx.fillRect(0, 0, width, height, TFT_RED);
  gfx.setFont(&fonts::efontJA_10);
  gfx.setTextColor(TFT_WHITE, TFT_RED);
  gfx.setTextSize(2);
  gfx.drawString("SERVO OFF 未確認", 8, 12);
  gfx.setTextSize(1);
  char line[96];
  std::snprintf(line, sizeof(line), "読み戻し: %s",
                pet::servoPowerVerdictName(notice.verdict));
  gfx.drawString(line, 8, 60);
  std::snprintf(line, sizeof(line), "再書込 %lu / 読取失敗 %lu / 不一致 %lu",
                static_cast<unsigned long>(notice.rewriteCount),
                static_cast<unsigned long>(notice.readFailureCount),
                static_cast<unsigned long>(notice.mismatchCount));
  gfx.drawString(line, 8, 80);
  gfx.drawString("シリアルの SAFE 行を記録してください", 8, 100);
}

void drawNotices(lgfx::LovyanGFX& gfx, const BoardNotice& notice,
                 std::int32_t width) {
  gfx.setFont(&fonts::efontJA_10);
  gfx.setTextSize(1);
  if (notice.powerMonitorFailed || notice.bleFailed) {
    char line[96];
    std::snprintf(line, sizeof(line), "%s%s",
                  notice.powerMonitorFailed ? "電池計(INA226)初期化失敗 " : "",
                  notice.bleFailed ? "BLE初期化失敗" : "");
    gfx.fillRect(0, 0, width, 16, TFT_YELLOW);
    gfx.setTextColor(TFT_BLACK, TFT_YELLOW);
    gfx.drawString(line, 4, 3);
  }
  if (notice.rewriteCount > 0) {
    char line[32];
    std::snprintf(line, sizeof(line), "VM再書込 %lu",
                  static_cast<unsigned long>(notice.rewriteCount));
    gfx.setTextColor(TFT_ORANGE, TFT_BLACK);
    gfx.drawString(line, width - gfx.textWidth(line) - 4, 20);
  }
}

}  // namespace

void FaceRenderer::begin(LGFX_Device& display) {
  display_ = &display;
  display_->fillScreen(TFT_BLACK);
  canvas_.setPsram(true);
  canvas_.setColorDepth(16);
  canvasReady_ = canvas_.createSprite(display_->width(), kUpperHeight) != nullptr;
  drawn_ = false;
}

void FaceRenderer::render(const pet::DisplayModel& model,
                          const BoardNotice& notice, std::uint32_t nowMs) {
  if (display_ == nullptr) {
    return;
  }
  pet::FacePose pose = pet::facePoseAt(model, nowMs);
  if (notice.servoPowerUnverified) {
    pose = pet::FacePose{};  // the fault screen does not animate
  }
  if (!drawn_ || pose != lastPose_ || notice != lastNotice_) {
    if (canvasReady_) {
      drawUpper(canvas_, pose, notice);
      canvas_.pushSprite(display_, 0, 0);
    } else {
      drawUpper(*display_, pose, notice);
    }
    lastPose_ = pose;
    lastNotice_ = notice;
  }
  if (!drawn_ || model.contentGeneration != lastContentGeneration_) {
    drawLower(model);
    lastContentGeneration_ = model.contentGeneration;
  }
  drawn_ = true;
}

void FaceRenderer::drawUpper(lgfx::LovyanGFX& target, const pet::FacePose& pose,
                             const BoardNotice& notice) {
  const std::int32_t width = display_->width();
  target.fillRect(0, 0, width, kUpperHeight, TFT_BLACK);
  if (notice.servoPowerUnverified) {
    drawFault(target, notice, width, kUpperHeight);  // replaces the face
    return;
  }
  drawFace(target, pose, width, kUpperHeight);
  drawNotices(target, notice, width);
}

void FaceRenderer::drawLower(const pet::DisplayModel& model) {
  LGFX_Device& display = *display_;
  const std::int32_t width = display.width();
  display.fillRect(0, kUpperHeight, width, display.height() - kUpperHeight, TFT_BLACK);
  display.setFont(&fonts::efontJA_10);
  display.setTextSize(2);
  display.setTextColor(model.connected ? TFT_WHITE : TFT_DARKGREY, TFT_BLACK);
  display.drawString(stateWord(model), kTextLeft, kStateTop);
  if (!model.connected || model.textLength == 0) {
    return;
  }
  display.setTextSize(1);
  display.setTextColor(TFT_WHITE, TFT_BLACK);
  const std::int32_t lineHeight = display.fontHeight() + 2;
  const std::size_t fit =
      static_cast<std::size_t>(std::max<std::int32_t>(0, (display.height() - kTextTop) / lineHeight));
  const std::size_t maxLines = std::min(kMaxTextLines, fit);
  char buffer[pet::kTextCapacity + 1];
  const auto measure = [&display, &buffer](const std::uint8_t* bytes, std::size_t length) {
    std::memcpy(buffer, bytes, length);
    buffer[length] = '\0';
    return static_cast<std::int32_t>(display.textWidth(buffer));
  };
  pet::LineSpan lines[kMaxTextLines];
  const std::size_t count = pet::layoutLines(model.text, model.textLength,
                                             width - 2 * kTextLeft, maxLines,
                                             measure, lines);
  for (std::size_t i = 0; i < count; ++i) {
    std::memcpy(buffer, model.text + lines[i].offset, lines[i].length);
    buffer[lines[i].length] = '\0';
    display.drawString(buffer, kTextLeft,
                       kTextTop + static_cast<std::int32_t>(i) * lineHeight);
  }
}

#endif  // !defined(PET_SAFEBOARD_PROBE)
```

`firmware/StackChanPet/RecordIntake.h`:

```cpp
#pragma once

// Logging wrapper around pet::toModelEvent (firmware/core/record_intake.hpp,
// host-tested). Kept out of the .ino so that Arduino's prototype generator
// never sees it.
#include "record_intake.hpp"

#include <Arduino.h>

inline pet::ModelEvent intakeWithLog(const pet::PetMailbox::Item& item) {
  const pet::Intake intake = pet::toModelEvent(item);
  if (Serial.availableForWrite() > 96) {
    if (item.kind == pet::EventKind::Disconnect) {
      Serial.printf("DISCONNECT t=%lu gen=%lu\n",
                    static_cast<unsigned long>(millis()),
                    static_cast<unsigned long>(item.generation));
    } else {
      Serial.printf("RX t=%lu gen=%lu len=%u result=%s\n",
                    static_cast<unsigned long>(millis()),
                    static_cast<unsigned long>(item.generation),
                    static_cast<unsigned>(item.length),
                    pet::recordErrorName(intake.error));
    }
  }
  return intake.event;
}
```

`PetPeripheral.cpp` と `FaceRenderer.cpp` は全体を `#if !defined(PET_SAFEBOARD_PROBE)` で囲んであり、プローブのビルドには BLE も描画も入らない。

`firmware/StackChanPet/StackChanPet.ino`（置き換え）:

```cpp
// StackChanPet: shows the AgentPets state sent over BLE (spec
// 2026-10-10-stackchan-ble-design.md). Never moves the head: there is no path
// that turns servo power on (spec 3.4).
//
// Build with -DPET_SAFEBOARD_PROBE=1 (scripts/build-firmware.sh --probe) for
// the SafeBoard-only probe: no BLE, no face, only the servo-power checks.
#include <M5StackChan.h>
#include <M5Unified.h>

#include "SafeBoard.h"

#if !defined(PET_SAFEBOARD_PROBE)
#include "FaceRenderer.h"
#include "PetPeripheral.h"
#include "RecordIntake.h"
#include "pet_display_model.hpp"
#include "pet_mailbox.hpp"
#endif

// The default 256-byte USB CDC TX ring cannot hold one burst of SAFE lines.
constexpr size_t kSerialTxBufferBytes = 4096;

SafeBoard safeBoard;

#if !defined(PET_SAFEBOARD_PROBE)
constexpr std::uint32_t kBootScreenHoldMs = 1500;

PetPeripheral peripheral;
FaceRenderer faceRenderer;
pet::PetDisplayModel displayModel;
#endif

void setup() {
  Serial.setTxBufferSize(kSerialTxBufferBytes);
  Serial.begin(115200);
#if defined(PET_SAFEBOARD_PROBE)
  safeBoard.begin(true);
#else
  safeBoard.begin(false);
  delay(kBootScreenHoldMs);  // leave the boot reading on screen briefly
  const bool bleOk = peripheral.begin();
  safeBoard.setBleFailed(!bleOk);
  faceRenderer.begin(M5.Display);
#endif
}

void loop() {
  M5.update();
  safeBoard.poll(millis());
#if !defined(PET_SAFEBOARD_PROBE)
  pet::PetMailbox::Item item;
  bool handled = false;
  while (peripheral.take(item)) {
    displayModel.update(intakeWithLog(item), millis());
    handled = true;
  }
  if (!handled) {
    displayModel.update(pet::ModelEvent{}, millis());  // watchdog
  }
  faceRenderer.render(displayModel.view(), safeBoard.notice(), millis());
#endif
  delay(1);
}
```

`scripts/capture-serial.py`:

```python
#!/usr/bin/env python3
"""Record the StackChanPet serial log without sending anything.

  .cache/esptool-legacy/bin/python -I scripts/capture-serial.py <port> <seconds> <out.log>

DTR and RTS are held low before the port opens (same intent as the PoC's
"RTS false" captures) so opening the port is not meant to reset the board.
Whether it resets anyway is visible in the log: SAFE lines carry t=<ms>.
"""
import sys
import time

import serial  # pyserial from the esptool 4.12.0 venv


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    port, seconds, out_path = sys.argv[1], float(sys.argv[2]), sys.argv[3]
    link = serial.Serial()
    link.port = port
    link.baudrate = 115200
    link.timeout = 0.2
    link.dtr = False
    link.rts = False
    link.open()
    deadline = time.monotonic() + seconds
    total = 0
    with open(out_path, "wb") as out:
        while time.monotonic() < deadline:
            chunk = link.read(4096)
            if chunk:
                out.write(chunk)
                total += len(chunk)
    link.close()
    print(f"captured {total} bytes in {seconds:.0f} s to {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 2: 両方をビルドし、検査を通す**

```bash
chmod +x scripts/capture-serial.py
scripts/build-firmware.sh; echo "exit=$?"
scripts/build-firmware.sh --probe; echo "exit=$?"
scripts/check-core.sh 2>&1 | tail -12; echo "exit=${PIPESTATUS[0]}"
NM=$(ls .cache/arduino/data/packages/esp32/tools/esp-x32/*/bin/xtensa-esp32s3-elf-nm)
"$NM" -C .cache/firmware-build/StackChanPet.ino.elf | grep -E 'PetPeripheral::onWrite|FaceRenderer::render|M5StackChan_Class::forceServoPowerOff'
"$NM" -C .cache/firmware-build-probe/StackChanPet.ino.elf | grep -c 'BLEServer::\|FaceRenderer::' ; echo "grep-exit=$?"
```

Expected: 本体・プローブとも `check-elf-safety: ok`、配置検査の出力、`exit=0`。`check-core.sh` も `exit=0`。本体の ELF に 3 つのシンボルが出る。プローブの ELF には `BLEServer::` も `FaceRenderer::` も無い（`0`、`grep-exit=1`。Task 10 で書くのはこのプローブ）。

`Sketch uses ... bytes` の行を記録する（app0 は 0x300000 = 3145728 バイト）。

コンパイルエラーの直し方は Task 8 Step 3 と同じ（保守側、Deviations に記録、`check-servo-writes.sh` を再実行）。

- [ ] **Step 3: 自己レビュー（実機に出す前）**

次を目で確かめ、結果を作業メモに書く:
- `onWrite` / `onConnect` / `onDisconnect` がクリティカルセクション内で mailbox を触る以外のこと（描画・Serial・I2C）をしていない
- 描画・I2C・Serial はすべて `loop()` / `setup()` から
- `SafeBoard::poll` が BLE の処理より前に毎ループ呼ばれる
- `forceServoPowerOff` の呼び出しは `SafeBoard::writeOffAndVerify` の 1 箇所だけ（`grep -rn forceServoPowerOff firmware`）

- [ ] **Step 4: Commit**

```bash
git add firmware/StackChanPet/PetPeripheral.h firmware/StackChanPet/PetPeripheral.cpp firmware/StackChanPet/FaceRenderer.h firmware/StackChanPet/FaceRenderer.cpp firmware/StackChanPet/RecordIntake.h firmware/StackChanPet/StackChanPet.ino scripts/capture-serial.py
git status --porcelain
git commit -m "Show the AgentPets state over BLE as a face, a state word and a subtitle"
```

---

### Task 10: 実機 — SafeBoard だけのプローブ（ユーザーと一緒に行う）

自動で進めない。各「ユーザー確認」で止まり、明示の了承を得てから次へ進む。了承が無ければそこで終える。

**前提:** Task 1〜9 の commit。`scripts/check-core.sh` と `scripts/build-firmware.sh --probe` をこのタスクの直前に再実行し、生出力の末尾を残す。

**Files:**
- Create: `docs/hardware-results.md`
- 非管理: `.cache/device/`, `.cache/backups/`, `.cache/hw/`

- [ ] **Step 1: ユーザー確認（書き込みの前提）**

ユーザーに次を伝え、それぞれ答えをもらう。答えを記録に残す。
1. 対象は StackChan K151 か。
2. 今入っているファームウェアで首が動作状態（arm）でないこと、首が正面にあること。
3. 復旧手段: 主は「書き込み前に今の app 領域を読み出して保存し、戻すときは `0x10000` へ書く」（PoC で app 書き込みの実績が多い）。副は工場の全体イメージ `write_flash 0x0 ~/agent-work/uwb-stackchan-poc/.cache/backups/k151-fw-1.5.1-full.bin`（SHA-256 `7a3576b27f76873f8c3b87e504de37ac93c91105b4b9a9da90010684cfed372b`、PoC で digest 照合済み）だが、**この復元の書き込みは一度も試験していない**こと。
4. このプローブは BLE も顔も出さず、サーボ電源 OFF の確認だけをすること。首を動かす経路は無いが、電源投入から OFF を書くまで（約 0.2〜1.4 秒）の状態は保証しないこと。
5. 次の照合（Step 2 の `read_mac`）で本体がリセットされ、今のファームウェアが止まってダウンロードモードに入ること。書き込みの了承（Step 5）はその後に別に取ること。書き込みを断った場合は、本体のリセットか電源の入れ直しで今のファームウェアに戻ること。

- [ ] **Step 2: ポートと機体を照合する**

```bash
ls /dev/cu.usbmodem*
```

ユーザーに出力を見せ、どれが K151 かを答えてもらう（以下 `PORT`）。

```bash
PORT=/dev/cu.usbmodemXXXX   # ユーザーの答え
.cache/esptool-legacy/bin/python -m esptool --chip esp32s3 --port "$PORT" --baud 921600 --after no_reset read_mac 2>&1 | tail -6
```

Expected: `Chip is ESP32-S3`、`MAC: <K151 の MAC アドレス>`（PoC の書き込みログ `.cache/*-upload.log` に記録された K151 の MAC）。違えば止まってユーザーに報告する（別の機体の可能性）。

- [ ] **Step 3: 実機のパーティション表を照合する（不一致なら中止）**

```bash
mkdir -p .cache/device
.cache/esptool-legacy/bin/python -m esptool --chip esp32s3 --port "$PORT" --baud 921600 --after no_reset read_flash 0x8000 0xC00 .cache/device/partitions-device.bin 2>&1 | tail -3
shasum -a 256 .cache/device/partitions-device.bin .cache/firmware-build-probe/StackChanPet.ino.partitions.bin
cmp .cache/device/partitions-device.bin .cache/firmware-build-probe/StackChanPet.ino.partitions.bin && echo PARTITIONS_MATCH
```

Expected: 2 つの SHA-256 が同じで `PARTITIONS_MATCH`。一致しなければ **中止**（工場 FW の配置では app0 が 0x20000 で、0x10000 への書き込みは工場 app を壊す）。ユーザーに報告し、パーティション表を書き換える案は出さずに止まる。

- [ ] **Step 4: 今の app 領域を保存する（主の復旧手段）**

```bash
mkdir -p .cache/backups
STAMP=$(date +%Y%m%d-%H%M%S)
.cache/esptool-legacy/bin/python -m esptool --chip esp32s3 --port "$PORT" --baud 921600 --after no_reset read_flash 0x10000 0x300000 ".cache/backups/app0-before-$STAMP.bin" 2>&1 | tail -3
.cache/esptool-legacy/bin/python -m esptool --chip esp32s3 --port "$PORT" --baud 921600 --after no_reset verify_flash 0x10000 ".cache/backups/app0-before-$STAMP.bin" 2>&1 | tail -3
shasum -a 256 ".cache/backups/app0-before-$STAMP.bin"
```

Expected: `Read 3145728 bytes at 0x00010000`、`-- verify OK (digest matched)`。SHA-256 を記録に書く。失敗したら止まって報告する。

`--after no_reset` で読んだ後、ESP32 は ROM のダウンロードモードに留まる（今の FW は止まっている）。Step 5 でユーザーが書き込みを断ったら、本体のリセットか電源の入れ直しで元の FW に戻ることを伝えて終える。

- [ ] **Step 5: ユーザー確認（書き込みの直前）**

Step 2〜4 の結果（ポート、MAC、パーティション一致、バックアップの SHA-256）を見せ、「app 領域 `0x10000` にプローブを書く」ことの了承をもらう。

- [ ] **Step 6: プローブを書き、ESP32 リセット後の状態を記録する**

```bash
git rev-parse HEAD
shasum -a 256 .cache/firmware-build-probe/StackChanPet.ino.bin
mkdir -p .cache/hw
.cache/esptool-legacy/bin/python -m esptool --chip esp32s3 --port "$PORT" --baud 921600 --after hard_reset write_flash 0x10000 .cache/firmware-build-probe/StackChanPet.ino.bin 2>&1 | tee .cache/hw/probe-upload.log | tail -4
.cache/esptool-legacy/bin/python -I scripts/capture-serial.py "$PORT" 15 .cache/hw/probe-after-reset.log
grep -m3 'SAFE BOOT-READ' .cache/hw/probe-after-reset.log; grep -m1 'SAFE BOOT-OFF' .cache/hw/probe-after-reset.log; grep 'SAFE CHECK' .cache/hw/probe-after-reset.log | tail -3
```

Expected: `Hash of data verified.`、`Hard resetting via RTS pin...`。`SAFE BOOT-READ` は「直前の FW（PoC）が動いていた状態から ESP32 だけがリセットされた」ときの PY32 の値（spec §5「ESP32 のリセットで PY32 の出力が保持されるか」の記録）。ESP32 が PoC FW を止めたのは Step 2 の `read_mac`（ダウンロードモードへ入れたリセット）の時点で、その間 PY32 は動き続けている。この時刻の流れも記録に書く。`BOOT-OFF` と `CHECK` が `consistent=1 verdict=off`。シリアルのポート名がリセットで変わったら `ls /dev/cu.usbmodem*` で取り直す。

ユーザーに画面の表示（`BOOT` と `NOW` の行）を読み上げるか写真で残してもらい、首が動かなかったかを答えてもらう。

- [ ] **Step 7: 電源投入直後の状態を記録する**

ユーザーに StackChan の電源を完全に切ってもらい（USB を抜き、本体の電源も切る。K151 の電源の切り方はユーザーの知っている手順で。計画作成時に手順は確認していない）、10 秒以上おいてから USB をつなぎ電源を入れてもらう。起動後 5 秒以上たってから:

```bash
ls /dev/cu.usbmodem*
.cache/esptool-legacy/bin/python -I scripts/capture-serial.py "$PORT" 15 .cache/hw/probe-power-on.log
grep -m1 'SAFE BOOT-READ' .cache/hw/probe-power-on.log; grep -m1 'SAFE BOOT-OFF' .cache/hw/probe-power-on.log; grep 'SAFE CHECK' .cache/hw/probe-power-on.log | tail -3
```

`BOOT-READ` は 1 秒ごとに再掲されるので、取り込みが遅れても電源投入直後の値が残る。画面の `BOOT` 行も記録する。首が動かなかったかを答えてもらう。

- [ ] **Step 8: 判定（止まる条件）**

- `consistent=0` が一度でも出た → まとめ読みが単独読みと合わない。止まって報告する（spec §3.4 のまとめ読みの前提を見直す必要がある）。
- `BOOT-OFF` か以後の `CHECK` が `verdict=off` でない、または `rewrites` が増え続ける → 止まって報告する。
- 首が動いた → ただちにユーザーに電源を切ってもらい、止まって報告する。

- [ ] **Step 9: 記録を書く**

`docs/hardware-results.md` を作る:

```markdown
# 実機結果

各記録には日時、commit、ビルドの SHA-256、手順、観察、生ログの末尾を残す。未実施を PASS と書かない。ホストテストとビルドは実機確認の代わりにしない。

## H1 SafeBoard プローブ — <日時 JST>

- commit: <git rev-parse HEAD>、プローブ bin の SHA-256: <sha>
- 機体: K151（ユーザー回答）、ポート <PORT>（ユーザー照合）、MAC <read_mac の出力>
- パーティション表: 実機 <sha> / ビルド <sha>（一致）
- app 領域の保存: `.cache/backups/app0-before-<STAMP>.bin`、SHA-256 <sha>、verify OK
- ユーザー確認: 現 FW が arm でない <回答>、首が正面 <回答>、工場全体復元が未試験であることを伝えた <日時>

| 記録 | 値（raw） |
|---|---|
| ESP32 リセット後（直前は PoC FW）の BOOT-READ | <行> |
| 同 BOOT-OFF | <行> |
| 電源投入直後の BOOT-READ | <行> |
| 同 BOOT-OFF | <行> |
| PY32 が入力モードの間に書いた出力値を保持したか | <BOOT-READ の M の pin0 と BOOT-OFF の O の pin0 から。M の pin0 が 1 なら「入力モードではなかったので判定できない」> |
| 首が動かなかったか | <ユーザー回答 × 2> |

生ログ末尾: <各ログの SAFE 行 3〜5 行>
```

- [ ] **Step 10: Commit**

```bash
git add docs/hardware-results.md
git status --porcelain
git commit -m "Record the SafeBoard probe on the K151"
```

---

### Task 11: 実機 — 本ファームウェアと Mac の結合確認（ユーザーと一緒に行う）

**前提:** Task 4（共有ベクタ）と Task 10 が完了。AgentPets 側の Mac 計画の `StackChanLink` とメニューが実装済みで、ユーザーがアプリを起動できること。`scripts/check-core.sh`、`scripts/check-vectors.sh ~/work/tools/AgentPets`、`scripts/build-firmware.sh` を直前に再実行し、生出力の末尾を残す。

- [ ] **Step 1: ユーザー確認と照合**

Task 10 Step 1 の 5 点を改めて伝え（プローブの代わりに本ファームウェアを書くこと、BLE で第三者が表示を偽装・接続を占有できることを含める）、了承をもらう。Task 10 Step 2・3（ポート、MAC、パーティション表の照合。照合はこの本体ビルドの `.cache/firmware-build/StackChanPet.ino.partitions.bin` と行う）を繰り返す。app 領域は Task 10 で保存済み（プローブが入っている今の領域を残したい場合だけ、Task 10 Step 4 を別名で繰り返す）。

- [ ] **Step 2: 書き込みと起動の確認**

```bash
git rev-parse HEAD
shasum -a 256 .cache/firmware-build/StackChanPet.ino.bin
.cache/esptool-legacy/bin/python -m esptool --chip esp32s3 --port "$PORT" --baud 921600 --after hard_reset write_flash 0x10000 .cache/firmware-build/StackChanPet.ino.bin 2>&1 | tee .cache/hw/pet-upload.log | tail -4
.cache/esptool-legacy/bin/python -I scripts/capture-serial.py "$PORT" 15 .cache/hw/pet-boot.log
grep 'SAFE' .cache/hw/pet-boot.log | tail -3
```

Expected: `Hash of data verified.`。`SAFE CHECK ... consistent=1 verdict=off`。画面は灰色の顔と「未接続」。首が動かないことをユーザーに確かめてもらう。

- [ ] **Step 3: Mac とつなぐ**

ユーザーに AgentPets のメニューで「StackChan に送る」をオンにしてもらう。シリアルを記録しながら確認する（`capture-serial.py` を確認ごとに 30〜60 秒で回す。`RX` / `DISCONNECT` 行の `t=` で時刻を読む）。

| # | 操作（ユーザー） | 期待 | spec |
|---|---|---|---|
| I1 | オンにする | メニューが「接続中」、StackChan に AgentPets の今の状態が出る。`RX ... result=none` が 5 秒ごと | §1.4 |
| I2 | `agentpets-notify.sh` などで状態を変える（idle → working → waiting → error） | 各状態の顔と語。文が出る。スマートフォンの動画（30 fps）に Mac の画面と StackChan を一緒に写し、Mac 側の変化から StackChan の変化までのフレーム数を数える | 成功条件 1（1 秒以内） |
| I3 | 跳ねる合図が出る操作（第 1 期 §2.3 の完了） | 顔が 1 回上下する | 成功条件 2 |
| I4 | 何もせず 15 秒以上待つ | 跳ねない（keep-alive） | §1.3 |
| I5 | オフ → オン | 未接続 → 接続。再接続で跳ねない | §1.3、§1.4 |
| I6 | オンのまま AgentPets を終了する | 切断を検知してすぐ「未接続」（`DISCONNECT` 行） | §1.4 |
| I7 | StackChan の電源を入れ直す | Mac が再接続し、表示が戻る。`SAFE BOOT-OFF ... verdict=off` | §1.4、§3.4 |
| I8 | 接続中に、別の端末（例: iPhone の BLE スキャナアプリ。ユーザーが持っていれば）でスキャンする | `StackChanPet` が見えない（単一接続で advertising が止まる） | §3.3。未検証事項 |
| I9 | manual で `·` と `…` と絵文字を含む文を送る | `·` `…` が描かれるか、欠けるか、絵文字がどう出るかを写真で記録 | spec §5 |
| I10 | 長い日本語の文（120 文字）を送る | 3 行で切れ、文字化けしない | §3.2 |

watchdog（接続したまま 15 秒無受信で未接続）は Mac アプリからは起こせない。ユーザーが汎用の BLE central（例: iPhone の BLE スキャナアプリ）を持っていれば、Mac をオフにしてからそれで接続し、characteristic に正しいレコード（例 `01010000`: 版 1・working・番号 0・文なし）を 1 回書いて 15 秒待つ（未接続になる）、不正なレコード（例 `02010000`）を 5 秒ごとに書いても 15 秒で未接続になる、を確かめる。持っていなければ「未実施」と記録する。

- [ ] **Step 4: 記録を書く**

`docs/hardware-results.md` に「H2 本ファームウェアと Mac の結合 — <日時>」を足す。commit、bin の SHA-256、パーティション照合、I1〜I10 と watchdog の各結果（観察・動画のフレーム数と計算・該当する `RX` / `DISCONNECT` / `SAFE` 行の raw）、未実施の項目は「未実施」と理由。Mac 側の `maximumWriteValueLength` の実測は Mac 計画の記録を参照先として書く（自分で測っていない値は写さない）。

- [ ] **Step 5: Commit**

```bash
git add docs/hardware-results.md
git status --porcelain
git commit -m "Record the StackChanPet and AgentPets integration on the K151"
```

---

## Self-Review 結果

- spec の網羅: §1.1 GATT → Task 9。§1.2 レコード → Task 3。§1.3 受信規則 → Task 3（拒否）、Task 5（跳ねる・keep-alive・watchdog 非延長）、Task 9（拒否を `None` にする配線）。§1.4 生存確認 → Task 5、Task 9（`advertiseOnDisconnect`）、Task 11。§1.5 → Task 9（ペアリングなし）、Task 2・8（首を動かす経路なし）。§3.1 → Task 1・2。§3.2 → Task 5・7・9。§3.3 → Task 9、Task 11 I8。§3.4 → Task 2・6・8、Task 10。§3.5 → Task 10・11。§3.6 → 各タスクのテスト、Task 4、Task 10・11。§4 の順番 → Task 1〜9（ファームウェア側）、Task 10・11（実機）。§5 → Task 10（PY32 の状態）、Task 11（グリフ、単一接続）。
- spec からの補足（Deviations として記録する）: `partitions.csv` はスケッチ直下（spec の構成図は repo 直下。arduino-cli の custom scheme と PoC のビルドスクリプトがスケッチ直下を読むため）。BSP から spec の列挙以上に削ったもの（Task 2）。`readServoPowerConfig` は生のバイトを返し解釈は core。まとめ読みに単独読みの照合を足し、OFF の書き込みは単独読みの値から作る（Task 8）。`forceServoPowerOff` は出力値の書き込みが NACK なら方向を書かない。idle の状態語 `待機中`。表情の時間定数（Task 7）。状態語は `efontJA_10` の 2 倍（大きいフォントを足さない）。拒否理由の判定順（Task 3・4）。mailbox の取り出し順と世代番号の規則（Task 5）。
- 確認した一次ソース: spec（3470945）、PoC の `scripts/{build-firmware.sh,check-core.sh,patch-arduino-core.py,check-flash-layout.py}`、`firmware/StackChanTracker/{partitions.csv,TrackingPeripheral.*,Firmware.cpp}`、`firmware/dependencies.lock.json`、`firmware/patches/arduino-nvs-label.patch`、BSP の `M5StackChan.{h,cpp}` と `PY32IOExpander.{hpp,cpp}`、M5Unified の `I2C_Class.hpp` / `I2C_Class.inl` / `IOExpander_Base.hpp`、M5GFX の `LGFX_Sprite.hpp` / `LGFXBase.hpp` / `M5GFX.h` / `misc/enum.hpp`、esp32 core 3.3.11 の `libraries/BLE/src/{BLEServer.*,BLECharacteristic.*}` と ESP32-S3 の `sdkconfig`、`platform.txt`、`boards.txt`、PoC の `docs/hardware-results.md` / `docs/verification/{k151-backup.md,bsp-baseline.md,original-face-layout.md,power-probe.md}` と書き込みログ。
- 計画作成時に実行したもの: core の全ヘッダとホストテストを scratch で `c++ -std=c++17 -Wall -Wextra -Werror` でコンパイル・実行（全部 ok）、各タスクの変異が落ちること、`check-servo-writes.sh` / `test-safety-checks.sh` / `check-vectors.sh` の正例・反例、`check-elf-safety.sh` が PoC の ELF で落ちること。スケッチと BSP の変更は Arduino ビルドしていない（Task 8・9 が初回のビルド）。
- 計画レビュー（サブエージェント、REVISE）を反映済み: Task 2 Step 1 の `0x6F` の grep が BMI270 に当たる件、Task 2 Step 4 の grep が provenance のコメントに当たる件、USB CDC の TX リング（既定 256 バイト）で SAFE 行が落ちる件（`setTxBufferSize(4096)` と BOOT-READ を先に出す）、書き込み検査の抜け道（まとめ書き・直接のバス書き込み・アドレスの拡散・読み取り側での書き込み・書き順）とその反例、プローブに BLE が入る件、読み取り失敗と不一致の数え分け、`.ino` の関数のヘッダ化、ダウンロードモードに留まる件。受け入れたもの: 跳ねる動作は `millis()` の一周（約 49.7 日）ごとに 1 回、誤って跳ねうる（`celebrateAtMs` が古いまま残るため。実害が小さいので直さない）。
- Fable による計画レビュー（REVISE）を反映済み: 変異の確認を commit の後に移し `git checkout -- <file>` で戻す手順にした（未 commit のファイルに変異が残らないように）、拒否レコード → `EventKind::None` の変換を core の `record_intake.hpp` に移してホストでテスト（拒否 write を実際に流して表示も watchdog も変わらないこと）、まとめ読みと単独読みの照合と書く値の元を core の `combineReadback` に移してホストでテスト、`read_mac` で今の FW が止まることを Step 1 で伝える、PoC の jj は `--ignore-working-copy`、commit trailer のモデル名を固定しない。
- 未検証（計画の中で確かめる手順を置いたもの）: PY32 のまとめ読みのアドレス自動加算（Task 8 の照合、Task 10）、電源投入直後と ESP32 リセット後の PY32 の状態（Task 10）、接続中に advertising が止まること（Task 11 I8）、`efontJA_10` の `·` `…` と絵文字（Task 11 I9）、`capture-serial.py` がポートを開くときにリセットしないこと（ログの `t=` で判別）、K151 の電源の切り方（ユーザーに聞く）、スケッチのコンパイル（Task 8・9）。
