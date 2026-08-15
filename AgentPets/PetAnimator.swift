//
//  PetAnimator.swift
//  AgentPets
//

import Foundation
import Observation
import QuartzCore

/// クリップを再生し、いま出すべきフレームを持つ。
///
/// フレームの決定は `PetAnimation` の純粋関数に任せ、こちらは時計とタイマーだけを見る。
@MainActor
@Observable
final class PetAnimator {
    private(set) var slot = 0

    /// 動きを減らす設定のときに立てる。先頭フレームで止め、タイマーを張らない。
    var isStill = false {
        didSet { if isStill != oldValue { restart() } }
    }

    /// ループしないクリップが最後まで来たときに 1 度だけ呼ばれる。
    var onFinished: (() -> Void)?

    private var clip: AnimationClip?
    private var startedAt: CFTimeInterval = 0
    private var timer: Timer?
    private var hasFinished = false

    var frameIndex: Int? {
        guard let clip, clip.frameIndices.indices.contains(slot) else { return nil }
        return clip.frameIndices[slot]
    }

    func play(_ clip: AnimationClip?) {
        self.clip = clip
        restart()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func restart() {
        stop()
        slot = 0
        hasFinished = false
        startedAt = CACurrentMediaTime()

        guard let clip, !isStill, clip.durations.count > 1 else { return }
        schedule()
    }

    private func schedule() {
        guard let clip else { return }

        let elapsed = CACurrentMediaTime() - startedAt
        slot = PetAnimation.slot(
            elapsed: elapsed, durations: clip.durations, repeats: clip.repeats
        )

        guard let boundary = PetAnimation.nextBoundary(
            after: elapsed, durations: clip.durations, repeats: clip.repeats
        ) else {
            if !hasFinished {
                hasFinished = true
                onFinished?()
            }
            return
        }

        // 「今から何秒後」ではなく再生開始からの絶対時刻で決めるので、誤差が累積しない。
        // tolerance は既定の 0 のまま。0.02 でも 5 秒で 1 割ずれる。
        // Timer.scheduledTimer は .default モードにしか入らず、メニューを開いた瞬間に止まる。
        let fire = Timer(fire: Date(timeIntervalSinceNow: max(0, boundary - elapsed)),
                         interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        }
        fire.tolerance = 0
        RunLoop.main.add(fire, forMode: .common)
        timer = fire
    }
}
