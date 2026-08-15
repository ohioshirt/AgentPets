//
//  PetDisplayTests.swift
//  AgentPetsTests
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AgentPets

@Suite("PetDisplay")
struct PetDisplayTests {

    @Test("シートが無ければ絵文字に落ちる")
    func fallsBackToEmoji() {
        #expect(PetDisplay.mode(sheet: nil) == .emoji)
    }

    @Test("吹き出しはメッセージが空なら出さない")
    func hidesEmptyBubble() {
        #expect(PetDisplay.showsBubble(message: "") == false)
        #expect(PetDisplay.showsBubble(message: "   ") == false)
        #expect(PetDisplay.showsBubble(message: "ビルド中") == true)
    }

    @Test("シートがあればスプライトを出す")
    func usesSpriteWhenLoaded() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("atlas-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let context = try #require(CGContext(
            data: nil, width: 1536, height: 1872, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))

        let sheet = try SpriteSheet.load(contentsOf: url, frame: nil)

        #expect(PetDisplay.mode(sheet: sheet) == .sprite)
    }
}
