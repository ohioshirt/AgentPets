//
//  PetViewModelTests.swift
//  AgentPetsTests
//

import Testing
@testable import AgentPets

@Suite("PetViewModel.apply")
@MainActor
struct PetViewModelTests {

    @Test("payloadのstateとmessageをそのまま反映する")
    func appliesPayload() {
        let viewModel = PetViewModel()

        viewModel.apply(StatusPayload(state: .working, message: "ビルド中"))

        #expect(viewModel.currentState == .working)
        #expect(viewModel.message == "ビルド中")
    }

    @Test("workingのまま通知が途絶えたらidleへ戻る")
    func fallsBackToIdleWhenWorkingGoesQuiet() async throws {
        let viewModel = PetViewModel()
        viewModel.workingTimeout = 0.1

        viewModel.apply(StatusPayload(state: .working, message: "ビルド中"))
        #expect(viewModel.currentState == .working)

        try await Task.sleep(for: .milliseconds(400))

        #expect(viewModel.currentState == .idle)
        #expect(viewModel.message == "")
    }

    @Test("workingでない状態はタイムアウトで書き換えられない")
    func keepsNonWorkingStateAfterTimeout() async throws {
        let viewModel = PetViewModel()
        viewModel.workingTimeout = 0.1

        viewModel.apply(StatusPayload(state: .working, message: "ビルド中"))
        viewModel.apply(StatusPayload(state: .error, message: "失敗"))

        try await Task.sleep(for: .milliseconds(400))

        #expect(viewModel.currentState == .error)
        #expect(viewModel.message == "失敗")
    }

    @Test("workingが続く間は前回のタイムアウトで打ち切られない")
    func restartsTimeoutOnEachWorkingUpdate() async throws {
        let viewModel = PetViewModel()
        viewModel.workingTimeout = 0.4

        viewModel.apply(StatusPayload(state: .working, message: "1件目"))
        try await Task.sleep(for: .milliseconds(200))
        viewModel.apply(StatusPayload(state: .working, message: "2件目"))

        // 1件目のタイムアウト時刻(400ms)は過ぎているが、2件目の分(600ms)はまだ来ていない
        try await Task.sleep(for: .milliseconds(300))

        #expect(viewModel.currentState == .working)
        #expect(viewModel.message == "2件目")
    }

    @Test("applyのたびにイベント連番が増える")
    func incrementsEventID() {
        let viewModel = PetViewModel()
        let start = viewModel.eventID

        viewModel.apply(StatusPayload(state: .working, message: "1"))
        viewModel.apply(StatusPayload(state: .waiting, message: "2"))

        #expect(viewModel.eventID == start + 2)
    }

    @Test("同じ状態が連続してもイベント連番は増える")
    func incrementsEventIDOnRepeatedState() {
        let viewModel = PetViewModel()

        viewModel.apply(StatusPayload(state: .success, message: "done"))
        let first = viewModel.eventID
        viewModel.apply(StatusPayload(state: .success, message: "done"))

        #expect(viewModel.eventID == first + 1)
        #expect(viewModel.currentState == .success)
    }
}
