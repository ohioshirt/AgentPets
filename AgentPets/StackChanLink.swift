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
        // オフにした後に届いた発見で、オフのまま接続しない。
        guard isEnabled, self.peripheral == nil else { return }
        // 保留中の候補をスキャンが見つけただけなら、スキャンは止めない（その connect が戻らないと探さなくなる）。
        guard !candidates.contains(where: { $0.identifier == peripheral.identifier }) else { return }
        // 複数見つかっても最初の 1 台だけを使う（spec §1.1）。
        central.stopScan()
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
        // スキャンだけ再開する（retrieve をやり直すと、失敗を繰り返す機体で回り続けるため）。
        // 覚えた機体の connect が保留のままでも再開する。connect はタイムアウトしないので、
        // 候補が尽きるのを待つと、覚えた機体が手元に無いとき永久に探さなくなる。
        // 保留中の機体を再び見つけても、didDiscover が identifier で重複を弾く。
        if self.peripheral == nil, isEnabled, central.state == .poweredOn {
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
        // Bluetooth オフでは restartDiscovery が何もしないので、keep-alive と「接続中」をここで降ろす。
        stopKeepAlive()
        status = .searching
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
