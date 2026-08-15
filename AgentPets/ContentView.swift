import SwiftUI
import Playgrounds

@main struct MyApp: App {
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
    private var windowController: FloatingWindowController?
    private var listener: StatusNotificationListener?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = FloatingWindowController(rootView: ContentView(viewModel: viewModel))
        controller.showWindow(nil)
        windowController = controller

        let listener = StatusNotificationListener(viewModel: viewModel)
        listener.start()
        self.listener = listener
    }
}

struct ContentView: View {
    @State var viewModel: PetViewModel
    
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
                .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: viewModel.currentState == .working)
        }
        .frame(width: 180, height: 200)
        .background(Color.clear)
    }
}

// MARK: - AppKit Floating Transparent Window Controller
final class FloatingWindowController: NSWindowController {
    convenience init<Content: View>(rootView: Content) {
        let panel = NSPanel(
            contentRect: NSRect(
                x: 100,
                y: 100,
                width: 200,
                height: 200
            ),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
            defer: false
        )
        
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        let hostingView = NSHostingView(rootView: rootView)
        panel.contentView = hostingView
        
        self.init(window: panel)
    }
}

#Preview {
    ContentView(viewModel: PetViewModel())
}

#Playground {
    _ = 1 + 2
}
