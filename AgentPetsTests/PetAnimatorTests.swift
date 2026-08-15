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
    /// 1 フレーム進んだあとは動かないクリップ。タイマーが遅れても `slot` が巻き戻らないので、
    /// 「進んだこと」を負荷に左右されずに確かめられる。
    ///
    /// ループするクリップでこれをやってはいけない。`looping` は合計 150ms なので、発火が
    /// 遅れて 150ms を跨ぐと `slot` が 0 に戻り、待ち時間を伸ばしても伸ばした先でまた戻る。
    private let advancesThenParks = AnimationClip(
        frameIndices: [20, 21], durations: [0.02, 10], repeats: false
    )

    @Test("同じクリップを再生し直すと先頭に戻る")
    func restartsOnSameClip() async throws {
        let animator = PetAnimator()
        animator.play(advancesThenParks)
        try await Task.sleep(for: .milliseconds(150))
        #expect(animator.slot != 0, "先に進んでいないと、やり直しを確かめられない")

        animator.play(advancesThenParks)

        #expect(animator.slot == 0)
        #expect(animator.frameIndex == advancesThenParks.frameIndices.first)
    }

    @Test("クリップを差し替えると先頭に戻る")
    func restartsOnNewClip() async throws {
        let animator = PetAnimator()
        animator.play(advancesThenParks)
        try await Task.sleep(for: .milliseconds(150))
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
        try await Task.sleep(for: .milliseconds(500))

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

    @Test("ループするクリップは2周目以降も進み続ける")
    func keepAdvancingAcrossLoops() async throws {
        let animator = PetAnimator()

        animator.play(looping)
        try await Task.sleep(for: .milliseconds(250))

        #expect(animator.slot != 0, "ループが止まっていないことを確認")
    }
}
