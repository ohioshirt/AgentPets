//
//  FloatingWindowController.swift
//  AgentPets
//

import SwiftUI

/// 保存した矩形を戻すときの補正。
///
/// `contentMinSize` と `contentMaxSize` はユーザー操作によるリサイズにしか効かず、
/// `setFrame` は 20×20 も画面外も素通しする。壊れた保存値や、外部ディスプレイを外した
/// あとの復元でおかしなウィンドウが出ないよう、ここで丸める。
nonisolated enum WindowFrame {
    static func clamp(_ rect: NSRect, min minimum: NSSize, max maximum: NSSize, within bounds: NSRect) -> NSRect {
        var result = rect
        result.size.width = Swift.min(Swift.max(rect.width, minimum.width), maximum.width)
        result.size.height = Swift.min(Swift.max(rect.height, minimum.height), maximum.height)
        result.origin.x = Swift.min(Swift.max(result.origin.x, bounds.minX), bounds.maxX - result.width)
        result.origin.y = Swift.min(Swift.max(result.origin.y, bounds.minY), bounds.maxY - result.height)
        return result
    }
}

/// ペットを載せる、枠なし・背景透過・常に最前面のパネル。
/// 非アクティブなまま操作できるよう `.nonactivatingPanel` にしてある。
final class FloatingWindowController: NSWindowController {
    static let defaultContentSize = NSSize(width: 96, height: 104)
    static let maximumContentSize = NSSize(width: 384, height: 416)
    private static let frameKey = "petWindowFrame"

    convenience init<Content: View>(rootView: Content) {
        let panel = NSPanel(
            contentRect: NSRect(origin: CGPoint(x: 100, y: 100), size: Self.defaultContentSize),
            // .resizable を足すと、枠が無くても辺 3pt・隅 12〜15pt がリサイズ帯になる。
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentMinSize = Self.defaultContentSize
        panel.contentMaxSize = Self.maximumContentSize

        // NSHostingView をパネルの contentView に直に置くと、sizingOptions を空にしても
        // SwiftUI 側の理想サイズ（ここでは ContentView の .frame(minWidth: 96, minHeight: 104)）
        // へウィンドウが数十 ms 後に勝手に縮む。実測で、resetSize()/restoreFrame() の setFrame が
        // 直後に上書きされて効かなくなることを確認した。素の NSView に subview として載せ、
        // オートリサイジングマスクだけで追従させることでこれを避けている。
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width, .height]

        let container = NSView(frame: NSRect(origin: .zero, size: Self.defaultContentSize))
        container.addSubview(hostingView)
        hostingView.frame = container.bounds
        panel.contentView = container

        self.init(window: panel)
        panel.delegate = self
        restoreFrame()
    }

    /// 既定のサイズに戻す。位置はそのまま。
    func resetSize() {
        guard let window else { return }
        var frame = window.frame
        frame.size = window.frameRect(forContentRect: NSRect(origin: .zero, size: Self.defaultContentSize)).size
        window.setFrame(frame, display: true, animate: true)
        saveFrame()
    }

    func saveFrame() {
        guard let window else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.frameKey)
    }

    private func restoreFrame() {
        guard let window,
              let saved = UserDefaults.standard.string(forKey: Self.frameKey) else { return }

        let bounds = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        guard !bounds.isEmpty else { return }

        window.setFrame(
            WindowFrame.clamp(
                NSRectFromString(saved),
                min: Self.defaultContentSize,
                max: Self.maximumContentSize,
                within: bounds
            ),
            display: false
        )
    }
}

extension FloatingWindowController: NSWindowDelegate {
    func windowDidResize(_ notification: Notification) { saveFrame() }
    func windowDidMove(_ notification: Notification) { saveFrame() }
}
