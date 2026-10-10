//
//  StatusNotificationListenerTests.swift
//  AgentPetsTests
//

import AgentPetsCore
import Foundation
import Testing
@testable import AgentPets

@Suite("StatusNotificationListener", .serialized)
@MainActor
struct StatusNotificationListenerTests {

    @Test("v2 の通知を AgentEvent として渡す")
    func deliversV2() async throws {
        var received: [AgentEvent] = []
        let listener = StatusNotificationListener { received.append($0) }
        listener.start()

        let event = AgentEvent(source: .claude, session: "s", project: "p", kind: .turnCompleted, ts: 1)
        post(try #require(WireCodec.encode(event)))

        try await waitUntil { received.contains(event) }
    }

    @Test("旧形式の通知も manual イベントとして渡す")
    func deliversLegacy() async throws {
        var received: [AgentEvent] = []
        let listener = StatusNotificationListener { received.append($0) }
        listener.start()

        post(#"{"status":"success","message":"完了"}"#)

        try await waitUntil { received.contains { $0.source == .manual && $0.kind == .turnCompleted && $0.detail == "完了" } }
    }

    @Test("不正な通知は捨てる")
    func ignoresInvalid() async throws {
        var received: [AgentEvent] = []
        let listener = StatusNotificationListener { received.append($0) }
        listener.start()

        post(#"{"status":"pwned","message":"x"}"#)
        post(#"{"status":"waiting","message":"次の通知"}"#)

        // 後から送った正常な通知が届いた時点で、不正な方は捨てられたと判断できる。
        // 実 hook が同じ通知名で送ってくることがあるので、件数ではなく中身で判定する。
        try await waitUntil { received.contains { $0.detail == "次の通知" } }
        #expect(!received.contains { $0.detail == "x" })
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
