//
//  ContentView.swift
//  AgentPets
//

import SwiftUI

struct ContentView: View {
    // @Observable なので、@State で包まなくても body からの参照が追跡される。
    // 生成は AppDelegate 側なので、ここで所有権を持たせてはいけない。
    let viewModel: PetViewModel
    let library: PetLibrary

    var body: some View {
        VStack(spacing: 8) {
            if PetDisplay.showsBubble(message: viewModel.message) {
                SpeechBubble(message: viewModel.message)
            }

            switch PetDisplay.mode(sheet: library.sheet) {
            case .sprite:
                if let sheet = library.sheet, let pet = library.selection {
                    PetSpriteView(
                        sheet: sheet,
                        manifest: pet.manifest,
                        state: viewModel.currentState,
                        eventID: viewModel.eventID
                    )
                }
            case .emoji:
                emojiPet
            }
        }
        .frame(minWidth: 96, minHeight: 104)
        .background(Color.clear)
    }

    /// ペットが選ばれていないか、アトラスを読めなかったときの表示。
    private var emojiPet: some View {
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
}

#Preview {
    ContentView(viewModel: PetViewModel(), library: PetLibrary())
}
