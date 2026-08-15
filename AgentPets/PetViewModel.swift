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
