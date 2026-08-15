//
//  PetManifestTests.swift
//  AgentPetsTests
//

import Foundation
import Testing
@testable import AgentPets

@Suite("PetManifest")
struct PetManifestTests {

    private func json(_ raw: String) -> Data { Data(raw.utf8) }

    private let minimal = """
    {
      "id": "zundamon",
      "displayName": "Zundamon",
      "description": "A compact animated pet.",
      "spritesheetPath": "spritesheet.webp"
    }
    """

    @Test("4フィールドの最小形を読む")
    func decodesMinimal() throws {
        let manifest = try PetManifest.decode(json(minimal))

        #expect(manifest.id == "zundamon")
        #expect(manifest.displayName == "Zundamon")
        #expect(manifest.spritesheetPath == "spritesheet.webp")
        #expect(manifest.frame == nil)
        #expect(manifest.animations == nil)
    }

    @Test("frameとanimationsを持つ拡張形を読む")
    func decodesExtended() throws {
        let manifest = try PetManifest.decode(json("""
        {
          "id": "p", "displayName": "P", "description": "d",
          "spritesheetPath": "s.webp",
          "frame": { "width": 192, "height": 208, "columns": 8 },
          "animations": { "idle": { "frames": [0, 1, 2], "fps": 6 } }
        }
        """))

        #expect(manifest.frame == PetManifest.FrameSpec(width: 192, height: 208, columns: 8))
        #expect(manifest.animations?["idle"]?.frames == [0, 1, 2])
        #expect(manifest.animations?["idle"]?.fps == 6)
    }

    @Test("animationsにframesが無ければ既定値に落とさず失敗する")
    func rejectsAnimationWithoutFrames() {
        #expect(throws: (any Error).self) {
            try PetManifest.decode(json("""
            {
              "id": "p", "displayName": "P", "description": "d",
              "spritesheetPath": "s.webp",
              "animations": { "idle": { "fps": 6 } }
            }
            """))
        }
    }

    @Test("frameにcolumnsが無ければ失敗する")
    func rejectsFrameWithoutColumns() {
        #expect(throws: (any Error).self) {
            try PetManifest.decode(json("""
            {
              "id": "p", "displayName": "P", "description": "d",
              "spritesheetPath": "s.webp",
              "frame": { "width": 192, "height": 208 }
            }
            """))
        }
    }

    @Test("知らないキーは無視する")
    func ignoresUnknownKeys() throws {
        let manifest = try PetManifest.decode(json("""
        {
          "id": "p", "displayName": "P", "description": "d",
          "spritesheetPath": "s.webp",
          "schemaVersion": 7,
          "frame": { "width": 192, "height": 208, "columns": 8, "rows": 9 }
        }
        """))

        #expect(manifest.id == "p")
        #expect(manifest.frame?.columns == 8)
    }

    @Test("必須フィールドが欠けていれば失敗する")
    func rejectsMissingRequiredField() {
        #expect(throws: (any Error).self) {
            try PetManifest.decode(json("""
            { "id": "p", "displayName": "P", "description": "d" }
            """))
        }
    }

    @Test("壊れたJSONは失敗する")
    func rejectsMalformedJSON() {
        #expect(throws: (any Error).self) {
            try PetManifest.decode(json("{ not json"))
        }
    }

    @Test("spritesheetPathをパッケージ内で解決する")
    func resolvesSpritesheetURL() throws {
        let manifest = try PetManifest.decode(json(minimal))
        let package = URL(fileURLWithPath: "/tmp/pets/zundamon", isDirectory: true)

        #expect(manifest.spritesheetURL(in: package)?.path == "/tmp/pets/zundamon/spritesheet.webp")
    }

    @Test("パッケージ外を指すspritesheetPathを拒否する")
    func rejectsEscapingSpritesheetPath() throws {
        let package = URL(fileURLWithPath: "/tmp/pets/zundamon", isDirectory: true)

        for path in ["../other/sheet.webp", "/etc/passwd", "../../sheet.webp"] {
            let manifest = try PetManifest.decode(json("""
            {
              "id": "p", "displayName": "P", "description": "d",
              "spritesheetPath": "\(path)"
            }
            """))

            #expect(manifest.spritesheetURL(in: package) == nil, "\(path) を拒否していない")
        }
    }
}
