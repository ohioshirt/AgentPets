//
//  WindowFrameTests.swift
//  AgentPetsTests
//

import AppKit
import Testing
@testable import AgentPets

@Suite("WindowFrame")
struct WindowFrameTests {

    private let minimum = NSSize(width: 96, height: 104)
    private let maximum = NSSize(width: 384, height: 416)
    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)

    @Test("下限より小さいサイズを引き上げる")
    func raisesTooSmall() {
        let clamped = WindowFrame.clamp(
            NSRect(x: 100, y: 100, width: 20, height: 20),
            min: minimum, max: maximum, within: screen
        )

        #expect(clamped.width == 96)
        #expect(clamped.height == 104)
    }

    @Test("上限より大きいサイズを切り詰める")
    func lowersTooLarge() {
        let clamped = WindowFrame.clamp(
            NSRect(x: 100, y: 100, width: 5000, height: 5000),
            min: minimum, max: maximum, within: screen
        )

        #expect(clamped.width == 384)
        #expect(clamped.height == 416)
    }

    @Test("画面の外に出た位置を引き戻す")
    func pullsBackOffscreen() {
        let clamped = WindowFrame.clamp(
            NSRect(x: 9000, y: -500, width: 96, height: 104),
            min: minimum, max: maximum, within: screen
        )

        #expect(screen.contains(clamped))
    }

    @Test("収まっている矩形はそのまま返す")
    func keepsValidFrame() {
        let rect = NSRect(x: 200, y: 300, width: 120, height: 130)

        #expect(WindowFrame.clamp(rect, min: minimum, max: maximum, within: screen) == rect)
    }
}
