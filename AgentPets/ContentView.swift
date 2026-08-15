//
//  ContentView.swift
//  AgentPets
//

import SwiftUI

struct ContentView: View {
    // @Observable なので、@State で包まなくても body からの参照が追跡される。
    // 生成は AppDelegate 側なので、ここで所有権を持たせてはいけない。
    let viewModel: PetViewModel

    var body: some View {
        VStack(spacing: 8) {
            // 吹き出し
            Text(viewModel.message)
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

            // ペット本体
            Text(viewModel.currentState.emoji)
                .font(.system(size: 28))
                .padding(16)
                .background(
                    Circle()
                        .fill(viewModel.currentState.color.opacity(0.85))
                        .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: 3)
                )
                .scaleEffect(viewModel.currentState == .working ? 1.1 : 1.0)
                .animation(
                    .easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                    value: viewModel.currentState == .working
                )
        }
        .frame(width: 180, height: 200)
        .background(Color.clear)
    }
}

#Preview {
    ContentView(viewModel: PetViewModel())
}
