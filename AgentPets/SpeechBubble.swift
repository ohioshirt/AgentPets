//
//  SpeechBubble.swift
//  AgentPets
//

import SwiftUI

/// ペットの上に出す吹き出し。表示するかどうかは呼び出し側が決める。
struct SpeechBubble: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.black)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
            )
            .lineLimit(2)
            .multilineTextAlignment(.center)
    }
}
