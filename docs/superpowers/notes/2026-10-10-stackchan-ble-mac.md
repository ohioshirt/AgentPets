# StackChan BLE（Mac 側）実機確認

- 日時: 2026-10-11
- AgentPets の commit: a53450a
- macOS / Mac の機種: macOS 27.0.1（26A434）/ MacBookPro18,3
- 相手: StackChan K151（ファームウェアの commit: stackchan-pet 3577a63、bin の SHA-256 9bad4399679b09d531972bcee1ed22e0f64684438892d5bbf560ac82c3de7a70）

## 1. 許可ダイアログ（spec §5「LSUIElement アプリでの Bluetooth 許可ダイアログの出方」）

- トグルがオフの起動で、ダイアログが出なかったか: 出なかった（2026-10-10、a53450a と同じ内容のビルド。メニューに「StackChan に送る」がチェックなしで出て、状態の行は「StackChan: 未使用」。ユーザー確認）
- 初めてトグルをオンにしたときのダイアログの出方（前面に出たか、メニューの裏に隠れたか）: 前面に出た（ユーザー回答）
- 「許可しない」を選んだときのメニューの行: 未実施（許可を選んだ）
- 許可した後のメニューの行: 「StackChan: 接続中 StackChanPet (9E2989F2-1FCD-4433-3115-FF4FD5E2AAD9)」相当の接続中の行（ユーザー回答「接続中になった」。文字列そのものは未記録）

## 2. 接続と実際の書き込み上限（spec §5「macOS の実際の maximumWriteValueLength」）

- `ready …` ログの行（そのまま貼る）:
  - `2026-10-11 00:15:54.962 Df AgentPets[98608:7ccf36] [AgentPets:StackChan] central state=5 enabled=true`
  - `2026-10-11 00:15:56.600 Df AgentPets[98608:7ccf36] [AgentPets:StackChan] ready StackChanPet 9E2989F2-1FCD-4433-3115-FF4FD5E2AAD9 maximumWriteValueLength(.withoutResponse)=253`
- maximumWriteValueLength(.withoutResponse) の値: 253（2 回の接続とも同じ）
- メニューの行（名前と identifier）: 名前 `StackChanPet`、identifier `9E2989F2-1FCD-4433-3115-FF4FD5E2AAD9`（ログから）

## 3. 送信（成功条件 1・2）

| 操作 | `write …` ログの hex | 相手側で見えた値・表示 | 変化から届くまで |
|---|---|---|---|
| `agentpets-notify.sh working "テスト実行中"` | `01010912e38386e382b9e38388e5ae9fe8a18ce4b8ad`（00:19:45.870） | 「作業中」・ニュートラルの顔・文「テスト実行中」 | 下の「遅れの測定」を参照 |
| `agentpets-notify.sh waiting "確認待ち"` | `0102090ce7a2bae8aa8de5be85e381a1`（00:20:02.290） | 「入力待ち」・？の顔・文 | 同上 |
| `agentpets-notify.sh error "テスト2件が失敗"` | `01040916e38386e382b9e3838832e4bbb6e3818ce5a4b1e69597`（00:20:13.660） | 「失敗」・悲しい顔・文 | 同上 |
| `agentpets-notify.sh success "完了テスト"` | `01030a0fe5ae8ce4ba86e38386e382b9e38388`（00:20:22.057。番号 09→0a） | 「完了」・笑顔・文、跳ねた | 未計測（success では測っていない） |
| もう一度 `agentpets-notify.sh success "完了テスト"` | `01030b0fe5ae8ce4ba86e38386e382b9e38388`（00:20:43.927。番号 0a→0b） | 跳ねた | 未計測 |
| メニューを開いたまま 15 秒 | 5 秒ごとに同じ hex（00:17:46〜00:23:45 の write 91 件で、隣り合う write の最大間隔 5.047 s） | 表示はそのまま、跳ねない（ユーザー回答） | — |

### 遅れの測定（成功条件 1）

- 方法: デスクトップのペット（`FanOutSink` で StackChan への送信と同じ呼び出しで表示が変わる）と StackChan の画面を iPhone 15 Pro で同じ画角に入れ、スローモーションで撮影（`evidence/IMG_2937.MOV`、git 管理外。書き出しは 30 fps・88.6 s・2658 フレーム）。撮影中に `agentpets-notify.sh error "ラグ測定"` と `waiting "ラグ測定"` を交互に送った（Mac の write: 00:54:06.501 / 13.424 / 19.655 / 24.346 / 29.265）
- 時間の尺度: 映像の中の変化（フレーム 135・955・1703・2265）の間隔 820・748・562 フレームと、Mac のログの間隔 6.923・6.231・4.691 s から、約 118〜120 フレーム／実時間 1 s
- 結果（フレームを並べて目視。ffmpeg で 12 フレームずつ切り出し）:

| 変化 | ペットが変わったフレーム | StackChan が描き始めたフレーム | 状態の語まで変わったフレーム |
|---|---|---|---|
| waiting→error | 955 | 957 | 960 |
| error→waiting | 1703 | 1705 | 1707 |
| waiting→error | 2265 | 2266 | 2270 |

- ペットの変化から StackChan の描き始めまで 1〜2 フレーム、語まで含めて描き終わるまで 4〜5 フレーム。120 フレーム／s として 8〜17 ms と 33〜42 ms。映像を実時間 30 fps と仮定した最悪でも 167 ms 以下で、1 秒以内を満たす
- 測っているのは「Mac の画面のペットの変化」からの差で、ペット自身の描画の遅れは含まない

## 4. 切断・Bluetooth オフ・スリープ復帰（spec §5「スリープ復帰時の CoreBluetooth の挙動」）

- 相手の電源を切った（シミュレータは公開を止めた）ときのメニューの行と `didDisconnect` ログ: 電源を切ると `didDisconnect … error=Optional(Error Domain=CBErrorDomain Code=6 "The connection has timed out unexpectedly." …)`（01:07:56.683）。メニューの行は記録していない。ほかに、シリアルを開いたときの StackChan のリセットで `didDisconnect … error=Optional(Error Domain=CBErrorDomain Code=6 "The connection has timed out unexpectedly." …)`（00:17:46.943）
- 相手を戻したときの再接続（同じ identifier か）: 電源投入後、同じ identifier `9E2989F2-…` で `ready`（01:09:23.444）。メニューは「接続中」に戻り、StackChan の表示も戻った（ユーザー回答）。シリアルのリセットのときも同じ identifier で `ready`（00:17:50.661、切断から約 3.7 s）
- コントロールセンターで Bluetooth をオフ → オン: `didDisconnect … error=nil`（00:27:07.853）の 12 ms 後に `central state=4`（00:27:07.865）。`didDisconnect` が状態更新より先に届いた（Task 4 の F3 の順序）。`state=5`（00:27:18.362）から `ready` まで 3.6 s。StackChan は 00:27:07.8 に `DISCONNECT gen=2`。その後 00:27:37.881 にもう一度 `state=4`→00:27:48.696 `state=5` があり、このときは `didDisconnect` も StackChan の `DISCONNECT` も無く、`ready` は state=5 の 9 ms 後（OS 側でリンクが残っていたと推定）。2 回目の操作の内容は未確認
- スリープ → 復帰（`didWake` ログ、再接続までの時間）: `state=4`（00:27:58.732）→ 復帰で `state=5`（00:28:38.573）→ `ready`（00:28:38.590）→ `didWake: redo discovery`（00:28:38.820）→ 自分の取り消しの `didDisconnect … error=nil`（00:28:38.865）→ `ready`（00:28:40.355）。スリープ中も StackChan との BLE リンクは切れず（`DISCONNECT` 無し、RX が約 40 s 途切れた）、StackChan は watchdog で少し遅れて「未接続」になった（ユーザー回答）
  - Task 4 レビュー P2-2: 順は ready → didWake → didDisconnect → ready。取り消しの `didDisconnect` は再接続の前に届き、作り直しの繰り返しは起きなかった（余分な繋ぎ直し 1 回、約 1.5 s）
- トグルをオフにしたとき（`write` ログが止まるか、相手側が切断を見たか）: `didDisconnect … error=nil`（00:26:38.364）、StackChan は 00:26:38.3 に `DISCONNECT gen=1`。オンに戻すと 0.9 s で `ready`、再接続で跳ねない（ユーザー回答）
- オンのまま AgentPets を終了 → 起動: StackChan はすぐ「未接続」（ユーザー回答、`DISCONNECT gen=4`）。起動し直すと `state=5`（00:29:21.142）→ `ready`（00:29:22.118）で自動接続。最初の write は `01000000`（idle・番号 0・文なし。番号はアプリ起動ごとに 0 から）

## 5. delegate の隔離（spec §5「isolated conformance の実行時チェック」）

- 上の操作の間にアプリが落ちなかったか: 落ちなかった。PID は 98608 → 7958 の 1 回だけ変わり、これはユーザーの終了・起動による
- `~/Library/DiagnosticReports/` に `AgentPets` のクラッシュレポートが増えていないか: このディレクトリはこの Mac に無い。クラッシュレポートの置き場所は `~/Library/Logs/DiagnosticReports/`（計画の手順のパスが違っていた）。そこにある `AgentPets` のレポートは 3 件（`AgentPets-2026-10-10-233403.ips`・`233405`・`233407`）で、どれも Task 3 の adversary が `/private/tmp` の写しで走らせた変異テスト（`StackChanSinkTests.wraps()` 内の `arithmetic overflow`。`&+=` を `+=` に変えたもの）。確認に使ったアプリ（23:59:30 起動、PID 98608 と 7958）のレポートは無い。isolated conformance の実行時チェックで落ちたことは一度も無かった

## 気づいたこと

- ログの取り方: `log stream --predicate 'subsystem == "AgentPets"' --level debug --style compact` をファイルへ（stackchan-pet の `.cache/hw/mac-log-t11.log`・`mac-log-t11b.log`）。StackChan 側は同じ時間帯にシリアルを 1 本開いたまま記録（`.cache/hw/pet-session-t11*.log`）
- このセッション（Claude Code）の hook も AgentPets に届くため、確認中の表示には自分の作業（`Bash · AgentPets` など）と Stop の「完了」が混ざる。manual の working は約 10 秒で戻る（`ReducerConfig` の TTL）。番号は Stop のたびにも 1 増えた（08・0d）
- ユーザーは 1 回目の手順の後に同じ手順をもう一度流した（00:21:18〜00:22:12）。2 回目も同じ hex 列で、success で番号 0b→0c
- 受信側（シリアル）: 00:17:46〜00:23:46 の `RX` 94 件すべて `result=none`、`DISCONNECT` 0
- 接続中の advertising: 接続中は iPhone の nRF Connect に `StackChanPet` が出ず、Mac と切れているときだけ出た（ユーザー回答）
- 文字の表示（計画 B Task 11 I9・I10、写真あり）: `·` と `…` は描かれる。絵文字 `🎉👍🏽` は豆腐 3 個（修飾子 🏽 も 1 個）。120 文字の日本語は Mac 側で 82 文字＋`…`（L=0xf9=249 バイト。253−4）に切られ、3 行に収まって文字化けなし
