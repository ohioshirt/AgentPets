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
