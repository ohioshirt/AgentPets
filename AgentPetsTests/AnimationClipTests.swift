//
//  AnimationClipTests.swift
//  AgentPetsTests
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AgentPets

@Suite("PetAnimation")
struct AnimationClipTests {

    private let durations: [TimeInterval] = [0.1, 0.2, 0.3]   // 合計 0.6

    private func json(_ raw: String) -> Data { Data(raw.utf8) }

    @Test("ループは経過時間の剰余でフレームを選ぶ")
    func loopsByRemainder() {
        let slot = { PetAnimation.slot(elapsed: $0, durations: durations, repeats: true) }

        #expect(slot(0.00) == 0)
        #expect(slot(0.05) == 0)
        #expect(slot(0.10) == 1)
        #expect(slot(0.29) == 1)
        #expect(slot(0.30) == 2)
        #expect(slot(0.59) == 2)
        #expect(slot(0.60) == 0)   // 2周目の先頭
        #expect(slot(0.95) == 2)   // 2周目の 0.35 の位置
        #expect(slot(1.25) == 0)   // 3周目の 0.05 の位置
    }

    @Test("ループしない場合は最終フレームで止まる")
    func clampsAtLastFrame() {
        let slot = { PetAnimation.slot(elapsed: $0, durations: durations, repeats: false) }

        #expect(slot(0.00) == 0)
        #expect(slot(0.30) == 2)
        #expect(slot(0.60) == 2)
        #expect(slot(99.0) == 2)
    }

    @Test("負の経過時間と空の配列でも落ちない")
    func handlesDegenerateInput() {
        #expect(PetAnimation.slot(elapsed: -5, durations: durations, repeats: true) == 0)
        #expect(PetAnimation.slot(elapsed: 1, durations: [], repeats: true) == 0)
        #expect(PetAnimation.slot(elapsed: 1, durations: [0, 0], repeats: true) == 0)
    }

    @Test("次の切り替え時刻を絶対時刻で返す")
    func computesNextBoundary() throws {
        let next = { PetAnimation.nextBoundary(after: $0, durations: durations, repeats: true) }

        #expect(try #require(next(0.00)).isApproximately(0.1))
        #expect(try #require(next(0.05)).isApproximately(0.1))
        #expect(try #require(next(0.10)).isApproximately(0.3))
        #expect(try #require(next(0.35)).isApproximately(0.6))
        #expect(try #require(next(0.60)).isApproximately(0.7))   // 2周目
    }

    @Test("ループしない場合は最後まで来たら次の切り替えが無い")
    func stopsBoundaryAtEnd() throws {
        let next = { PetAnimation.nextBoundary(after: $0, durations: durations, repeats: false) }

        #expect(try #require(next(0.35)).isApproximately(0.6))
        #expect(next(0.60) == nil)
        #expect(next(5.00) == nil)
    }

    @Test("5つの状態すべてにアトラス上の行が対応する")
    func mapsEveryState() {
        let states: Set<PetState> = [.idle, .working, .waiting, .success, .error]

        #expect(Set(PetAnimation.stateAnimations.keys) == states)

        for (state, animation) in PetAnimation.stateAnimations {
            let row = PetAnimation.rows[animation.name]
            #expect(row != nil)
            #expect((row?.index ?? -1) < 9)
        }
    }

    @Test("既定スケジュールのフレーム数と合計時間が仕様と一致する")
    func matchesPublishedSchedule() throws {
        // animation-rows.md の Used columns と表示時間
        let expected: [String: (frames: Int, total: TimeInterval)] = [
            "idle":          (6, 1.100),
            "running-right": (8, 1.060),
            "running-left":  (8, 1.060),
            "waving":        (4, 0.700),
            "jumping":       (5, 0.840),
            "failed":        (8, 1.220),
            "waiting":       (6, 1.010),
            "running":       (6, 0.820),
            "review":        (6, 1.030),
        ]

        #expect(Set(PetAnimation.rows.keys) == Set(expected.keys))

        for (name, want) in expected {
            let row = try #require(PetAnimation.rows[name])
            #expect(row.durations.count == want.frames)
            #expect(row.durations.reduce(0, +).isApproximately(want.total))
        }
    }

    @Test("行の並びが仕様どおり")
    func matchesRowOrder() throws {
        let order = ["idle", "running-right", "running-left", "waving",
                     "jumping", "failed", "waiting", "running", "review"]

        for (index, name) in order.enumerated() {
            #expect(try #require(PetAnimation.rows[name]).index == index)
        }
    }

    @Test("既定では行のフレーム番号が行×columns＋列になる")
    func defaultFrameIndices() throws {
        let sheet = try makeAtlas(width: 32, height: 36)
        defer { try? FileManager.default.removeItem(at: sheet) }

        let spriteSheet = try SpriteSheet.load(contentsOf: sheet,
            frame: PetManifest.FrameSpec(width: 4, height: 4, columns: 8))

        let manifest = try PetManifest.decode(json("""
            {
              "id": "test",
              "displayName": "Test",
              "description": "Test pet",
              "spritesheetPath": "\(sheet.path)"
            }
        """))

        // working → running is row 7 with 6 frames
        let clip = try #require(PetAnimation.clip(for: .working, manifest: manifest, sheet: spriteSheet))
        #expect(clip.frameIndices == [56, 57, 58, 59, 60, 61])
        #expect(clip.durations == PetAnimation.rows["running"]?.durations)
        #expect(clip.repeats)
    }

    @Test("successとerrorはループしない")
    func nonRepeatingStates() throws {
        let sheet = try makeAtlas(width: 32, height: 36)
        defer { try? FileManager.default.removeItem(at: sheet) }

        let spriteSheet = try SpriteSheet.load(contentsOf: sheet,
            frame: PetManifest.FrameSpec(width: 4, height: 4, columns: 8))

        let manifest = try PetManifest.decode(json("""
            {
              "id": "test",
              "displayName": "Test",
              "description": "Test pet",
              "spritesheetPath": "\(sheet.path)"
            }
        """))

        let successClip = try #require(PetAnimation.clip(for: .success, manifest: manifest, sheet: spriteSheet))
        #expect(!successClip.repeats)

        let errorClip = try #require(PetAnimation.clip(for: .error, manifest: manifest, sheet: spriteSheet))
        #expect(!errorClip.repeats)

        let idleClip = try #require(PetAnimation.clip(for: .idle, manifest: manifest, sheet: spriteSheet))
        #expect(idleClip.repeats)

        let workingClip = try #require(PetAnimation.clip(for: .working, manifest: manifest, sheet: spriteSheet))
        #expect(workingClip.repeats)

        let waitingClip = try #require(PetAnimation.clip(for: .waiting, manifest: manifest, sheet: spriteSheet))
        #expect(waitingClip.repeats)
    }

    @Test("manifestのanimationsが既定より優先される")
    func manifestAnimationsOverride() throws {
        let sheet = try makeAtlas(width: 32, height: 36)
        defer { try? FileManager.default.removeItem(at: sheet) }

        let spriteSheet = try SpriteSheet.load(contentsOf: sheet,
            frame: PetManifest.FrameSpec(width: 4, height: 4, columns: 8))

        let manifest = try PetManifest.decode(json("""
            {
              "id": "test",
              "displayName": "Test",
              "description": "Test pet",
              "spritesheetPath": "\(sheet.path)",
              "animations": {
                "running": {
                  "frames": [3, 4]
                }
              }
            }
        """))

        let clip = try #require(PetAnimation.clip(for: .working, manifest: manifest, sheet: spriteSheet))
        #expect(clip.frameIndices == [3, 4])
    }

    @Test("fpsが指定されていれば等間隔になる")
    func fpsSpecified() throws {
        let sheet = try makeAtlas(width: 32, height: 36)
        defer { try? FileManager.default.removeItem(at: sheet) }

        let spriteSheet = try SpriteSheet.load(contentsOf: sheet,
            frame: PetManifest.FrameSpec(width: 4, height: 4, columns: 8))

        let manifest = try PetManifest.decode(json("""
            {
              "id": "test",
              "displayName": "Test",
              "description": "Test pet",
              "spritesheetPath": "\(sheet.path)",
              "animations": {
                "running": {
                  "frames": [0, 1, 2, 3],
                  "fps": 4
                }
              }
            }
        """))

        let clip = try #require(PetAnimation.clip(for: .working, manifest: manifest, sheet: spriteSheet))
        #expect(clip.durations == [0.25, 0.25, 0.25, 0.25])
    }

    @Test("シートの外を指すframesは拒否する")
    func rejectsOutOfBoundsFrames() throws {
        let sheet = try makeAtlas(width: 32, height: 36)
        defer { try? FileManager.default.removeItem(at: sheet) }

        let spriteSheet = try SpriteSheet.load(contentsOf: sheet,
            frame: PetManifest.FrameSpec(width: 4, height: 4, columns: 8))

        let manifest = try PetManifest.decode(json("""
            {
              "id": "test",
              "displayName": "Test",
              "description": "Test pet",
              "spritesheetPath": "\(sheet.path)",
              "animations": {
                "running": {
                  "frames": [0, 999]
                }
              }
            }
        """))

        let clip = PetAnimation.clip(for: .working, manifest: manifest, sheet: spriteSheet)
        #expect(clip == nil)
    }

    @Test("行がシートに無ければnilを返す")
    func rejectsRowOutsideSheet() throws {
        // Create a small sheet with only 3 rows
        let sheet = try makeAtlas(width: 32, height: 12)
        defer { try? FileManager.default.removeItem(at: sheet) }

        let spriteSheet = try SpriteSheet.load(contentsOf: sheet,
            frame: PetManifest.FrameSpec(width: 4, height: 4, columns: 8))

        let manifest = try PetManifest.decode(json("""
            {
              "id": "test",
              "displayName": "Test",
              "description": "Test pet",
              "spritesheetPath": "\(sheet.path)"
            }
        """))

        // error is row 5, which is outside the 3-row sheet
        let clip = PetAnimation.clip(for: .error, manifest: manifest, sheet: spriteSheet)
        #expect(clip == nil)
    }
}

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

private extension TimeInterval {
    func isApproximately(_ other: TimeInterval) -> Bool { abs(self - other) < 0.0005 }
}
