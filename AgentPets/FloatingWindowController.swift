//
//  FloatingWindowController.swift
//  AgentPets
//

import SwiftUI

/// ペットを載せる、枠なし・背景透過・常に最前面のパネル。
/// 非アクティブなまま操作できるよう `.nonactivatingPanel` にしてある。
final class FloatingWindowController: NSWindowController {
    convenience init<Content: View>(rootView: Content) {
        let panel = NSPanel(
            contentRect: NSRect(x: 100, y: 100, width: 200, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        panel.contentView = NSHostingView(rootView: rootView)

        self.init(window: panel)
    }
}
