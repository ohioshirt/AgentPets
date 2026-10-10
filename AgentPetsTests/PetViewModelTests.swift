//
//  PetViewModelTests.swift
//  AgentPetsTests
//

import AgentPetsCore
import Testing
@testable import AgentPets

@Suite("PetViewModel.show")
@MainActor
struct PetViewModelTests {
    let a = SessionKey(source: .claude, session: "a")
    let b = SessionKey(source: .claude, session: "b")

    func display(_ status: PetStatus, _ key: SessionKey?, celebrate: Bool = false, message: String = "", tooltip: String = "") -> DisplayState {
        DisplayState(status: status, message: message, tooltip: tooltip, sessionKey: key, celebrate: celebrate)
    }

    @Test("表示状態と文をそのまま反映する")
    func reflects() {
        let vm = PetViewModel()
        vm.show(display(.working, a, message: "作業中 · p", tooltip: "claude · p: 作業中"))
        #expect(vm.currentState == .working)
        #expect(vm.spriteState == .working)
        #expect(vm.message == "作業中 · p")
        #expect(vm.tooltip == "claude · p: 作業中")
    }

    @Test("celebrate 付きの success で跳ねる（spriteState が success、eventID が増える）")
    func celebrates() {
        let vm = PetViewModel()
        vm.show(display(.working, a))
        let before = vm.eventID
        vm.show(display(.success, a, celebrate: true))
        #expect(vm.spriteState == .success)
        #expect(vm.eventID == before + 1)
    }

    @Test("success のまま celebrate が続けて来ても毎回跳ねる（manual の連投）")
    func celebratesRepeatedly() {
        let vm = PetViewModel()
        vm.show(display(.success, a, celebrate: true))
        let before = vm.eventID
        vm.show(display(.success, a, celebrate: true))
        #expect(vm.spriteState == .success)
        #expect(vm.eventID == before + 1)
    }

    @Test("celebrate 無しの success は跳ねず、idle のクリップを流す（集約の切り替わり）")
    func noCelebrationOnSwitch() {
        let vm = PetViewModel()
        vm.show(display(.waiting, b))
        vm.show(display(.success, a))
        #expect(vm.currentState == .success)
        #expect(vm.spriteState == .idle)
    }

    @Test("同じ表示が続いても eventID は増えない")
    func stableOnSameDisplay() {
        let vm = PetViewModel()
        vm.show(display(.working, a))
        let before = vm.eventID
        vm.show(display(.working, a))
        #expect(vm.eventID == before)
    }

    @Test("spriteState が変わるたびに eventID が増える")
    func bumpsOnSpriteChange() {
        let vm = PetViewModel()
        let start = vm.eventID
        vm.show(display(.working, a))
        vm.show(display(.waiting, a))
        #expect(vm.eventID == start + 2)
    }
}
