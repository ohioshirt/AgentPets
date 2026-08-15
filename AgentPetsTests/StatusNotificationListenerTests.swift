//
//  StatusNotificationListenerTests.swift
//  AgentPetsTests
//

import Foundation
import Testing
@testable import AgentPets

@Suite("StatusNotificationListener", .serialized)
@MainActor
struct StatusNotificationListenerTests {

    @Test("購読中は配信された通知がviewModelに反映される")
    func appliesDeliveredNotification() async throws {
        let viewModel = PetViewModel()
        let listener = StatusNotificationListener(viewModel: viewModel)
        listener.start()

        post(#"{"status":"success","message":"完了"}"#)

        try await waitUntil { viewModel.currentState == .success }
        #expect(viewModel.message == "完了")
    }

    @Test("未知のstatusを載せた通知はviewModelを動かさない")
    func ignoresUnknownState() async throws {
        let viewModel = PetViewModel()
        let listener = StatusNotificationListener(viewModel: viewModel)
        listener.start()

        post(#"{"status":"pwned","message":"x"}"#)
        post(#"{"status":"waiting","message":"次の通知"}"#)

        // 後から送った正常な通知が届いた時点で、不正な方は捨てられたと判断できる
        try await waitUntil { viewModel.currentState == .waiting }
        #expect(viewModel.message == "次の通知")
    }

    private func post(_ payload: String) {
        DistributedNotificationCenter.default().postNotificationName(
            StatusNotificationListener.notificationName,
            object: payload,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("条件が \(timeout) 以内に成立しなかった")
    }
}
