//
//  PetViewModel.swift
//  AgentPets
//
//  Created by shigeo on 2026/08/15.
//

import AgentPetsCore
import Foundation
import Observation

@MainActor
@Observable
final class PetViewModel: DisplaySink {
    /// 絵文字表示と色に使う、集約結果そのものの状態。
    var currentState: PetState = .idle
    /// スプライトで再生する状態。集約の切り替わりで success が表に出たときは、
    /// 跳ねずに跳ねた後の姿（idle）を流すため currentState と分ける。
    var spriteState: PetState = .idle
    var message: String = ""

    /// スプライトをやり直す連番。同じ状態のまま跳ね直すときにも増やす。
    private(set) var eventID = 0

    /// 跳ねるかどうかは HubStore が `celebrate` で決める。ここは見た目への写像だけを持つ。
    func show(_ display: DisplayState) {
        let sprite: PetState = display.status == .success && !display.celebrate ? .idle : PetState(display.status)

        if display.celebrate || sprite != spriteState { eventID &+= 1 }
        currentState = PetState(display.status)
        spriteState = sprite
        message = display.message
    }
}

extension PetState {
    init(_ status: PetStatus) {
        switch status {
        case .idle: self = .idle
        case .working: self = .working
        case .waiting: self = .waiting
        case .success: self = .success
        case .error: self = .error
        }
    }
}
