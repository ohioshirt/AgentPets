//
//  AnimationClip.swift
//  AgentPets
//

import Foundation

/// 再生する準備が整ったアニメーション。
/// 状態・マニフェスト・固定契約はここに畳まれるので、再生側はこの型しか知らない。
nonisolated struct AnimationClip: Equatable {
    let frameIndices: [Int]
    let durations: [TimeInterval]
    /// false なら最終フレームで止まる。
    let repeats: Bool
}

nonisolated enum PetAnimation {

    nonisolated struct Row: Equatable {
        let index: Int
        let durations: [TimeInterval]
    }

    nonisolated struct StateAnimation: Equatable {
        let name: String
        let repeats: Bool
        /// 1 周したあとに移る状態。nil ならその場に留まる。
        let then: PetState?
    }

    private static func ms(_ values: Int...) -> [TimeInterval] {
        values.map { TimeInterval($0) / 1000 }
    }

    /// hatch-pet の animation-rows.md にある固定契約。
    static let rows: [String: Row] = [
        "idle":          Row(index: 0, durations: ms(280, 110, 110, 140, 140, 320)),
        "running-right": Row(index: 1, durations: ms(120, 120, 120, 120, 120, 120, 120, 220)),
        "running-left":  Row(index: 2, durations: ms(120, 120, 120, 120, 120, 120, 120, 220)),
        "waving":        Row(index: 3, durations: ms(140, 140, 140, 280)),
        "jumping":       Row(index: 4, durations: ms(140, 140, 140, 140, 280)),
        "failed":        Row(index: 5, durations: ms(140, 140, 140, 140, 140, 140, 140, 240)),
        "waiting":       Row(index: 6, durations: ms(150, 150, 150, 150, 150, 260)),
        "running":       Row(index: 7, durations: ms(120, 120, 120, 120, 120, 220)),
        "review":        Row(index: 8, durations: ms(150, 150, 150, 150, 150, 280)),
    ]

    /// 状態と行の対応。`PetState` は通信仕様の型なので、表示の都合はこちらに置く。
    ///
    /// success は跳ねてから待機に戻る。error は落ち込んだまま留まる。失敗が視界から消えると
    /// 状態表示として機能しないため。
    static let stateAnimations: [PetState: StateAnimation] = [
        .idle:    StateAnimation(name: "idle",    repeats: true,  then: nil),
        .working: StateAnimation(name: "running", repeats: true,  then: nil),
        .waiting: StateAnimation(name: "waiting", repeats: true,  then: nil),
        .success: StateAnimation(name: "jumping", repeats: false, then: .idle),
        .error:   StateAnimation(name: "failed",  repeats: false, then: nil),
    ]

    /// `animations` に fps しか無いときに使う、1 フレームあたりの時間。
    static let fallbackFrameDuration: TimeInterval = 0.15

    static func clip(for state: PetState, manifest: PetManifest, sheet: SpriteSheet) -> AnimationClip? {
        guard let animation = stateAnimations[state] else { return nil }

        if let spec = manifest.animations?[animation.name] {
            guard !spec.frames.isEmpty,
                  spec.frames.allSatisfy({ $0 >= 0 && $0 < sheet.frameCount }) else { return nil }

            let durations: [TimeInterval]
            if let fps = spec.fps, fps > 0, fps.isFinite {
                durations = Array(repeating: 1 / fps, count: spec.frames.count)
            } else if let row = rows[animation.name], row.durations.count == spec.frames.count {
                durations = row.durations
            } else {
                durations = Array(repeating: fallbackFrameDuration, count: spec.frames.count)
            }

            return AnimationClip(
                frameIndices: spec.frames, durations: durations, repeats: animation.repeats
            )
        }

        guard let row = rows[animation.name], row.index < sheet.rows else { return nil }
        let indices = (0..<row.durations.count).map { row.index * sheet.columns + $0 }
        guard indices.allSatisfy({ $0 < sheet.frameCount }) else { return nil }

        return AnimationClip(
            frameIndices: indices, durations: row.durations, repeats: animation.repeats
        )
    }

    /// 経過時間から表示すべきフレームの位置を返す。時計に触らないのでテストしやすい。
    ///
    /// 境界の比較には許容誤差が要る。`0.1 + 0.2` は `0.30000000000000004` になり、
    /// `[0.1, 0.2, 0.3]` の合計は `0.6000000000000001` になるので、厳密比較だと
    /// 境界ちょうどの時刻が 1 つ手前のフレームに落ちる。既定スケジュールの最短フレームは
    /// 110ms なので、1e-10 はそれより 9 桁小さく、実際の丸め誤差 1e-16 より 6 桁大きい。
    static func slot(elapsed: TimeInterval, durations: [TimeInterval], repeats: Bool) -> Int {
        guard !durations.isEmpty else { return 0 }
        let total = durations.reduce(0, +)
        guard total > 0 else { return 0 }

        var position = max(0, elapsed)
        if repeats {
            position = position.truncatingRemainder(dividingBy: total)
            if position >= total - 1e-10 {
                position = 0
            }
        } else if position >= total {
            return durations.count - 1
        }

        var accumulated: TimeInterval = 0
        for (index, duration) in durations.enumerated() {
            accumulated += duration
            if position < accumulated - 1e-10 { return index }
        }
        return durations.count - 1
    }

    /// 次にフレームが切り替わる時刻を、再生開始からの経過時間で返す。
    /// 「今から何秒後」ではなく絶対時刻で持つことで、タイマーの誤差が累積しない。
    static func nextBoundary(
        after elapsed: TimeInterval, durations: [TimeInterval], repeats: Bool
    ) -> TimeInterval? {
        guard !durations.isEmpty else { return nil }
        let total = durations.reduce(0, +)
        guard total > 0 else { return nil }

        let position = max(0, elapsed)
        if !repeats && position >= total - 1e-10 { return nil }

        var completedCycles = repeats ? (position / total).rounded(.down) : 0
        // 「いま居る周期の終わり」と比べる。`total` と比べると 2 周目以降は常に真になり、
        // `rounded(.down)` が既に数えた周をもう一度足してしまう。
        if repeats && position >= (completedCycles + 1) * total - 1e-10 {
            completedCycles += 1
        }
        var accumulated: TimeInterval = 0
        for duration in durations {
            accumulated += duration
            let boundary = completedCycles * total + accumulated
            if boundary > position { return boundary }
        }
        return repeats ? (completedCycles + 1) * total : nil
    }
}
