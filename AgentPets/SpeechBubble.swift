//
//  SpeechBubble.swift
//  AgentPets
//

import SwiftUI

/// ペットの上に出す吹き出し。表示するかどうかは呼び出し側が決める。
struct SpeechBubble: View {
    let message: String
    /// ホバー時に重ねて表示する全文。空ならホバーしても通常表示のまま（`.help` のツールチップも出ない）。
    var tooltip: String = ""

    @State private var isHovering = false

    /// ホバー中に全文を出せるか。全文が空なら通常表示のまま。
    private var expanded: Bool { isHovering && !tooltip.isEmpty }

    var body: some View {
        // 通常表示の Text をレイアウト用に残し（ホバーで ContentView の配置が動かないように）、
        // ホバー中はその上へ全文を重ねる。ウィンドウは 96pt 幅の固定寄りなので、
        // ウィンドウ自体は広げず、下のペットに被せて表示する。
        // 既知の制限（許容済み）: 96×104 のウィンドウ幅に制約されるため、120 文字近い長文（特に CJK）は
        // 下端で切れることがある。ウィンドウは意図的に広げない。
        bubble(Text(message).lineLimit(2))
            .opacity(expanded ? 0 : 1)
            .overlay(alignment: .top) {
                if expanded {
                    bubble(Text(tooltip).lineLimit(nil).fixedSize(horizontal: false, vertical: true))
                }
            }
            .onHover { isHovering = $0 }
            .help(tooltip)
    }

    private func bubble<Content: View>(_ text: Content) -> some View {
        text
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.black)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
            )
            .multilineTextAlignment(.center)
    }
}
