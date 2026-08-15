//
//  AnimationClipTests.swift
//  AgentPetsTests
//

import Foundation
import Testing
@testable import AgentPets

@Suite("PetAnimation")
struct AnimationClipTests {

    private let durations: [TimeInterval] = [0.1, 0.2, 0.3]   // 合計 0.6

    @Test("ループは経過時間の剰余でフレームを選ぶ")
    func loopsByRemainder() {
        let slot = { PetAnimation.slot(elapsed: $0, durations: durations, repeats: true) }

        #expect(slot(0.00) == 0)
        #expect(slot(0.05) == 0)
        #expect(slot(0.10) == 1)
        #expect(slot(0.29) == 1)
        #expect(slot(0.30) == 2)
        #expect(slot(0.59) == 2)
        #expect(slot(0.60) == 0)   // 2周目の先頭
        #expect(slot(0.95) == 2)   // 2周目の 0.35 の位置
        #expect(slot(1.25) == 0)   // 3周目の 0.05 の位置
    }

    @Test("ループしない場合は最終フレームで止まる")
    func clampsAtLastFrame() {
        let slot = { PetAnimation.slot(elapsed: $0, durations: durations, repeats: false) }

        #expect(slot(0.00) == 0)
        #expect(slot(0.30) == 2)
        #expect(slot(0.60) == 2)
        #expect(slot(99.0) == 2)
    }

    @Test("負の経過時間と空の配列でも落ちない")
    func handlesDegenerateInput() {
        #expect(PetAnimation.slot(elapsed: -5, durations: durations, repeats: true) == 0)
        #expect(PetAnimation.slot(elapsed: 1, durations: [], repeats: true) == 0)
        #expect(PetAnimation.slot(elapsed: 1, durations: [0, 0], repeats: true) == 0)
    }

    @Test("次の切り替え時刻を絶対時刻で返す")
    func computesNextBoundary() throws {
        let next = { PetAnimation.nextBoundary(after: $0, durations: durations, repeats: true) }

        #expect(try #require(next(0.00)).isApproximately(0.1))
        #expect(try #require(next(0.05)).isApproximately(0.1))
        #expect(try #require(next(0.10)).isApproximately(0.3))
        #expect(try #require(next(0.35)).isApproximately(0.6))
        #expect(try #require(next(0.60)).isApproximately(0.7))   // 2周目
    }

    @Test("ループしない場合は最後まで来たら次の切り替えが無い")
    func stopsBoundaryAtEnd() throws {
        let next = { PetAnimation.nextBoundary(after: $0, durations: durations, repeats: false) }

        #expect(try #require(next(0.35)).isApproximately(0.6))
        #expect(next(0.60) == nil)
        #expect(next(5.00) == nil)
    }

    @Test("5つの状態すべてにアトラス上の行が対応する")
    func mapsEveryState() {
        let states: Set<PetState> = [.idle, .working, .waiting, .success, .error]

        #expect(Set(PetAnimation.stateAnimations.keys) == states)

        for (state, animation) in PetAnimation.stateAnimations {
            let row = PetAnimation.rows[animation.name]
            #expect(row != nil)
            #expect((row?.index ?? -1) < 9)
        }
    }

    @Test("既定スケジュールのフレーム数と合計時間が仕様と一致する")
    func matchesPublishedSchedule() throws {
        // animation-rows.md の Used columns と表示時間
        let expected: [String: (frames: Int, total: TimeInterval)] = [
            "idle":          (6, 1.100),
            "running-right": (8, 1.060),
            "running-left":  (8, 1.060),
            "waving":        (4, 0.700),
            "jumping":       (5, 0.840),
            "failed":        (8, 1.220),
            "waiting":       (6, 1.010),
            "running":       (6, 0.820),
            "review":        (6, 1.030),
        ]

        #expect(Set(PetAnimation.rows.keys) == Set(expected.keys))

        for (name, want) in expected {
            let row = try #require(PetAnimation.rows[name])
            #expect(row.durations.count == want.frames)
            #expect(row.durations.reduce(0, +).isApproximately(want.total))
        }
    }

    @Test("行の並びが仕様どおり")
    func matchesRowOrder() throws {
        let order = ["idle", "running-right", "running-left", "waving",
                     "jumping", "failed", "waiting", "running", "review"]

        for (index, name) in order.enumerated() {
            #expect(try #require(PetAnimation.rows[name]).index == index)
        }
    }
}

private extension TimeInterval {
    func isApproximately(_ other: TimeInterval) -> Bool { abs(self - other) < 0.0005 }
}
