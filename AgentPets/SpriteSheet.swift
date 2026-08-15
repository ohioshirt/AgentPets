//
//  SpriteSheet.swift
//  AgentPets
//

import CoreGraphics
import Foundation
import ImageIO

nonisolated enum SpriteSheetError: Error, Equatable {
    case decodeFailed
    case invalidFrameSpec
    case widthMismatch
    case heightNotDivisible
}

/// スプライトアトラスと、そこから切り出したフレーム。
///
/// モジュール既定の分離が MainActor なので、`nonisolated` を明示して UI スレッドの外で
/// デコードできるようにしてある。1536×1872 のデコードは数十 ms かかる。
nonisolated struct SpriteSheet {
    let cellWidth: Int
    let cellHeight: Int
    let columns: Int
    let rows: Int

    private let atlas: CGImage

    var frameCount: Int { columns * rows }

    /// hatch-pet の固定契約。`pet.json` に `frame` が無いときはこれを使う。
    static let defaultFrame = PetManifest.FrameSpec(width: 192, height: 208, columns: 8)

    static func load(contentsOf url: URL, frame: PetManifest.FrameSpec?) throws -> SpriteSheet {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let atlas = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw SpriteSheetError.decodeFailed
        }

        let spec = frame ?? defaultFrame
        guard spec.width > 0, spec.height > 0, spec.columns > 0 else {
            throw SpriteSheetError.invalidFrameSpec
        }
        guard atlas.width == spec.width * spec.columns else {
            throw SpriteSheetError.widthMismatch
        }
        guard atlas.height % spec.height == 0, atlas.height >= spec.height else {
            throw SpriteSheetError.heightNotDivisible
        }

        return SpriteSheet(
            cellWidth: spec.width,
            cellHeight: spec.height,
            columns: spec.columns,
            rows: atlas.height / spec.height,
            atlas: atlas
        )
    }

    /// フレーム番号は「行 × columns ＋ 列」の平面インデックス。
    static func rect(forIndex index: Int, cellWidth: Int, cellHeight: Int, columns: Int) -> CGRect {
        CGRect(
            x: (index % columns) * cellWidth,
            y: (index / columns) * cellHeight,
            width: cellWidth,
            height: cellHeight
        )
    }

    func frame(at index: Int) -> CGImage? {
        guard index >= 0, index < frameCount else { return nil }
        return atlas.cropping(to: Self.rect(
            forIndex: index, cellWidth: cellWidth, cellHeight: cellHeight, columns: columns
        ))
    }
}
