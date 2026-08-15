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

    /// 2 つの矩形が重なる面積。複数ディスプレイのうち、保存された矩形が
    /// もともとどの画面にあったかを選ぶのに使う（`FloatingWindowController.screenBounds(for:)`）。
    static func overlapArea(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let intersection = a.intersection(b)
        return intersection.isNull ? 0 : intersection.width * intersection.height
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

        let savedRect = NSRectFromString(saved)
        guard let bounds = Self.screenBounds(for: savedRect) else { return }

        window.setFrame(
            WindowFrame.clamp(
                savedRect,
                min: Self.defaultContentSize,
                max: Self.maximumContentSize,
                within: bounds
            ),
            display: false
        )
    }

    /// 復元先の画面は、保存された矩形と最も重なるものを選ぶ。
    ///
    /// この時点でウィンドウはまだ画面に載っておらず `window.screen` は nil を返す。
    /// `NSScreen.main` はキーボードフォーカスのある画面なので、複数ディスプレイでは
    /// 起動のたびに変わりうる。保存された矩形は、それ自身がどこにあったかを知っている。
    private static func screenBounds(for frame: NSRect) -> NSRect? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }

        let best = screens.max { left, right in
            WindowFrame.overlapArea(frame, left.visibleFrame) < WindowFrame.overlapArea(frame, right.visibleFrame)
        }
        if let best, WindowFrame.overlapArea(frame, best.visibleFrame) > 0 { return best.visibleFrame }

        // どの画面とも重ならない（外したディスプレイに置いていた等）。主画面に引き戻す。
        return NSScreen.main?.visibleFrame ?? screens[0].visibleFrame
    }
}

extension FloatingWindowController: NSWindowDelegate {
    func windowDidResize(_ notification: Notification) { saveFrame() }
    func windowDidMove(_ notification: Notification) { saveFrame() }
}
