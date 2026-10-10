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
/// 跳ねる合図は `celebrateSeq` の変化で伝える。`display.celebrate` は付け替え時の再送でも true のまま残るので使わない。
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
