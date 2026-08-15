//
//  PetAnimatorTests.swift
//  AgentPetsTests
//

import Foundation
import Testing
@testable import AgentPets

@Suite("PetAnimator")
@MainActor
struct PetAnimatorTests {

    private let looping = AnimationClip(
        frameIndices: [0, 1, 2], durations: [0.05, 0.05, 0.05], repeats: true
    )
    private let once = AnimationClip(
        frameIndices: [10, 11], durations: [0.05, 0.05], repeats: false
    )

    @Test("再生を始めると先頭フレームから出す")
    func startsAtFirstFrame() {
        let animator = PetAnimator()

        animator.play(looping)

        #expect(animator.slot == 0)
    }

    @Test("クリップを差し替えると先頭に戻る")
    func restartsOnNewClip() async throws {
        let animator = PetAnimator()
        animator.play(looping)
        try await Task.sleep(for: .milliseconds(120))
        #expect(animator.slot != 0)

        animator.play(once)

        #expect(animator.slot == 0)
    }

    @Test("動きを減らす設定では先頭フレームのまま進まない")
    func staysStillWhenReduced() async throws {
        let animator = PetAnimator()
        animator.isStill = true

        animator.play(looping)
        try await Task.sleep(for: .milliseconds(200))

        #expect(animator.slot == 0)
    }

    @Test("ループしないクリップは終わったら通知する")
    func reportsFinish() async throws {
        let animator = PetAnimator()
        var finished = 0
        animator.onFinished = { finished += 1 }

        animator.play(once)
        try await Task.sleep(for: .milliseconds(250))

        #expect(finished == 1)
        #expect(animator.slot == 1)
    }

    @Test("ループするクリップでは終了を通知しない")
    func doesNotReportFinishWhenLooping() async throws {
        let animator = PetAnimator()
        var finished = 0
        animator.onFinished = { finished += 1 }

        animator.play(looping)
        try await Task.sleep(for: .milliseconds(250))

        #expect(finished == 0)
    }

    @Test("nilを渡すと止まる")
    func stopsOnNilClip() {
        let animator = PetAnimator()
        animator.play(looping)

        animator.play(nil)

        #expect(animator.slot == 0)
        #expect(animator.frameIndex == nil)
    }

    @Test("現在のフレーム番号をクリップから引く")
    func exposesFrameIndex() {
        let animator = PetAnimator()

        animator.play(once)

        #expect(animator.frameIndex == 10)
    }
}
