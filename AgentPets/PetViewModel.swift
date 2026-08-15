//
//  PetViewModel.swift
//  AgentPets
//
//  Created by shigeo on 2026/08/15.
//

import Foundation
import Observation

@MainActor
@Observable
final class PetViewModel {
    var currentState: PetState = .idle
    var message: String = ""

    private var guardTimer: Timer?

    /// working のまま音沙汰が無くなったときに idle へ戻すまでの秒数
    var workingTimeout: TimeInterval = 10

    func apply(_ payload: StatusPayload) {
        currentState = payload.state
        message = payload.message

        guardTimer?.invalidate()
        guard payload.state == .working else { return }

        // working のまま通知が途絶えた場合に備え、一定時間で idle へ戻す
        guardTimer = Timer.scheduledTimer(withTimeInterval: workingTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.currentState == .working else { return }
                self.apply(StatusPayload(state: .idle, message: ""))
            }
        }
    }
}
