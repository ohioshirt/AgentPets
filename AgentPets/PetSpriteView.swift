//
//  PetSpriteView.swift
//  AgentPets
//

import SwiftUI

/// 何をどう出すかの判定。`body` に埋めるとテストできないので関数にしてある。
nonisolated enum PetDisplay {
    enum Mode: Equatable { case sprite, emoji }

    static func mode(sheet: SpriteSheet?) -> Mode {
        sheet == nil ? .emoji : .sprite
    }

    static func showsBubble(message: String) -> Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// スプライトの描画。
///
/// 親と分けてあるのは依存追跡のため。`ContentView` の `body` でフレーム番号を読むと、
/// 毎秒 5〜8 回の更新のたびに吹き出しまで再評価される。
struct PetSpriteView: View {
    let sheet: SpriteSheet
    let manifest: PetManifest
    let state: PetState
    /// 同じ状態が連続で届いてもやり直せるように、値そのものではなく連番で見る。
    let eventID: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animator = PetAnimator()

    var body: some View {
        Group {
            if let index = animator.frameIndex, let image = sheet.frame(at: index) {
                // scale: 2 にすると Retina で 192×208 が 96×104 pt に 1:1 で乗る。
                Image(decorative: image, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .onAppear {
            animator.isStill = reduceMotion
            animator.onFinished = { advanceAfterOneShot() }
            play(state)
        }
        .onChange(of: eventID) { play(state) }
        .onChange(of: reduceMotion) { animator.isStill = reduceMotion }
        .onDisappear { animator.stop() }
    }

    private func play(_ state: PetState) {
        animator.play(PetAnimation.clip(for: state, manifest: manifest, sheet: sheet))
    }

    /// success は跳ねたあと待機に戻る。error は落ち込んだまま留まる。
    private func advanceAfterOneShot() {
        guard let next = PetAnimation.stateAnimations[state]?.then else { return }
        play(next)
    }
}
