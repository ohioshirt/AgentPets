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
            let library = appDelegate.library

            if library.pets.isEmpty {
                Text(library.isFolderMissing ? "ペットフォルダが見つかりません" : "ペットが未設定です")
            } else {
                ForEach(library.pets) { pet in
                    Button {
                        library.select(pet)
                    } label: {
                        Text(library.selection?.id == pet.id ? "✓ \(pet.displayName)" : pet.displayName)
                    }
                }
                Divider()
                Button("絵文字で表示") { library.select(nil) }
            }

            Divider()
            Button(library.folderURL == nil ? "ペットフォルダを選択…" : "ペットフォルダを変更…") {
                chooseFolder(for: library)
            }

            Divider()
            Button("サイズを既定に戻す") { appDelegate.windowController?.resetSize() }

            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }

    /// メニュートラッキング中に直接モーダルを出すと、パネルが裏に回ることがある。
    /// アクティブ化してから次の RunLoop に回す。
    private func chooseFolder(for library: PetLibrary) {
        DispatchQueue.main.async {
            NSApp.activate()

            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.showsHiddenFiles = true
            panel.prompt = "選択"
            panel.message = "ペットパッケージが入っているフォルダを選んでください。"

            guard panel.runModal() == .OK, let url = panel.url else { return }
            library.setFolder(url)
        }
    }
}

/// ペットのウィンドウと通知リスナーはアプリと同じ寿命で生きる必要がある。
/// Scene の body 評価中に `@State` へ書き戻すやり方では参照が保持されず、
/// リスナーが即座に解放されて購読が外れるため、delegate 側で所有する。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let viewModel = PetViewModel()
    let library = PetLibrary()
    private(set) var windowController: FloatingWindowController?
    private var listener: StatusNotificationListener?
    private var hub: HubStore?
    /// トグルに関係なく常設し、最新の表示状態と跳ねる番号を持ち続ける（spec §2.2）。
    private let stackChanSink = StackChanSink()

    func applicationDidFinishLaunching(_ notification: Notification) {
        library.restore()

        let controller = FloatingWindowController(
            rootView: ContentView(viewModel: viewModel, library: library)
        )
        controller.showWindow(nil)
        windowController = controller

        let hub = HubStore(sink: FanOutSink([viewModel, stackChanSink]))
        hub.start()
        self.hub = hub

        let listener = StatusNotificationListener { [weak hub] event in hub?.receive(event) }
        listener.start()
        self.listener = listener
    }

    func applicationWillTerminate(_ notification: Notification) {
        library.releaseFolderAccess()
    }
}
