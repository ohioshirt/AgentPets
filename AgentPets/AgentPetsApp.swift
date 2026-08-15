//
//  AgentPetsApp.swift
//  AgentPets
//

import SwiftUI

@main
struct AgentPetsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Pet", systemImage: "pawprint.fill") {
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

/// ペットのウィンドウと通知リスナーはアプリと同じ寿命で生きる必要がある。
/// Scene の body 評価中に `@State` へ書き戻すやり方では参照が保持されず、
/// リスナーが即座に解放されて購読が外れるため、delegate 側で所有する。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let viewModel = PetViewModel()
    let library = PetLibrary()
    private var windowController: FloatingWindowController?
    private var listener: StatusNotificationListener?

    func applicationDidFinishLaunching(_ notification: Notification) {
        library.restore()

        let controller = FloatingWindowController(
            rootView: ContentView(viewModel: viewModel, library: library)
        )
        controller.showWindow(nil)
        windowController = controller

        let listener = StatusNotificationListener(viewModel: viewModel)
        listener.start()
        self.listener = listener
    }
}
