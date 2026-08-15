//
//  SpriteSheetTests.swift
//  AgentPetsTests
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AgentPets

@Suite("SpriteSheet")
struct SpriteSheetTests {

    /// 実素材に依存しないよう、テスト内で不透明なアトラスPNGを作る。
    /// `.json` や `.md` と違い、一時ディレクトリに書けば製品バンドルには入らない。
    private func makeAtlas(width: Int, height: Int) throws -> URL {
        let context = try #require(CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.8, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("atlas-\(UUID().uuidString).png")
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test("既定の8×9アトラスを読む")
    func loadsDefaultAtlas() throws {
        let url = try makeAtlas(width: 1536, height: 1872)

        let sheet = try SpriteSheet.load(contentsOf: url, frame: nil)

        #expect(sheet.cellWidth == 192)
        #expect(sheet.cellHeight == 208)
        #expect(sheet.columns == 8)
        #expect(sheet.rows == 9)
        #expect(sheet.frameCount == 72)
    }

    @Test("幅がcolumns×widthと合わなければ失敗する")
    func rejectsWidthMismatch() throws {
        let url = try makeAtlas(width: 1500, height: 1872)

        #expect(throws: SpriteSheetError.widthMismatch) {
            try SpriteSheet.load(contentsOf: url, frame: nil)
        }
    }

    @Test("高さがセル高で割り切れなければ失敗する")
    func rejectsIndivisibleHeight() throws {
        let url = try makeAtlas(width: 1536, height: 1800)

        #expect(throws: SpriteSheetError.heightNotDivisible) {
            try SpriteSheet.load(contentsOf: url, frame: nil)
        }
    }

    @Test("manifestのframeがあればそちらを使う")
    func honorsManifestFrame() throws {
        let url = try makeAtlas(width: 120, height: 80)

        let sheet = try SpriteSheet.load(
            contentsOf: url,
            frame: PetManifest.FrameSpec(width: 40, height: 20, columns: 3)
        )

        #expect(sheet.rows == 4)
        #expect(sheet.frameCount == 12)
    }

    @Test("画像として読めないファイルは失敗する")
    func rejectsNonImage() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("not-an-image-\(UUID().uuidString).webp")
        try Data("hello".utf8).write(to: url)

        #expect(throws: SpriteSheetError.decodeFailed) {
            try SpriteSheet.load(contentsOf: url, frame: nil)
        }
    }

    @Test("フレーム番号を矩形に変換する")
    func convertsIndexToRect() {
        let rect = { SpriteSheet.rect(forIndex: $0, cellWidth: 192, cellHeight: 208, columns: 8) }

        #expect(rect(0) == CGRect(x: 0, y: 0, width: 192, height: 208))
        #expect(rect(7) == CGRect(x: 1344, y: 0, width: 192, height: 208))
        #expect(rect(8) == CGRect(x: 0, y: 208, width: 192, height: 208))
        #expect(rect(9) == CGRect(x: 192, y: 208, width: 192, height: 208))
    }

    @Test("範囲外のフレーム番号はnilを返す")
    func returnsNilForOutOfRangeIndex() throws {
        let sheet = try SpriteSheet.load(contentsOf: makeAtlas(width: 1536, height: 1872), frame: nil)

        #expect(sheet.frame(at: 0) != nil)
        #expect(sheet.frame(at: 71) != nil)
        #expect(sheet.frame(at: 72) == nil)
        #expect(sheet.frame(at: -1) == nil)
    }

    @Test("切り出したフレームはセルの大きさになる")
    func cropsToCellSize() throws {
        let sheet = try SpriteSheet.load(contentsOf: makeAtlas(width: 1536, height: 1872), frame: nil)

        let frame = try #require(sheet.frame(at: 42))

        #expect(frame.width == 192)
        #expect(frame.height == 208)
    }

    @Test("width/height/columnsが0以下のFrameSpecは失敗する")
    func rejectsInvalidFrameSpec() throws {
        let url = try makeAtlas(width: 120, height: 80)

        // width が 0 以下
        #expect(throws: SpriteSheetError.invalidFrameSpec) {
            try SpriteSheet.load(contentsOf: url, frame: PetManifest.FrameSpec(width: 0, height: 20, columns: 3))
        }

        // height が 0 以下
        #expect(throws: SpriteSheetError.invalidFrameSpec) {
            try SpriteSheet.load(contentsOf: url, frame: PetManifest.FrameSpec(width: 40, height: 0, columns: 3))
        }

        // columns が 0 以下
        #expect(throws: SpriteSheetError.invalidFrameSpec) {
            try SpriteSheet.load(contentsOf: url, frame: PetManifest.FrameSpec(width: 40, height: 20, columns: 0))
        }
    }
}
