import SwiftUI
import Playgrounds

@main struct MyApp: App {
    @State private var viewModel = PetViewModel()
    @State private var windowController: FloatingWindowController?
    @State private var server: LocalHTTPServer?
    
    var body: some Scene {
        MenuBarExtra("Pet", systemImage: "pawprint.fill") {
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .setupHook {
            if windowController == nil {
                let petView = ContentView(viewModel: viewModel)
                let controller = FloatingWindowController(rootView: petView)
                controller.showWindow(nil)
                self.windowController = controller
                
                // start HTTP server
                let server = LocalHTTPServer()
                server.start(port: 9999)
                self.server = server
            }
        }
    }
}

extension Scene {
    func setupHook(_ action: @escaping () -> Void) -> some Scene {
        action()
        return self
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
