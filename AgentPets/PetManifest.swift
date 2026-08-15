//
//  PetManifest.swift
//  AgentPets
//

import Foundation

/// ペットパッケージの `pet.json`。
///
/// 必須は hatch-pet の公開契約にある 4 つ。`frame` と `animations` は Codex CLI の内部モデルから
/// 推定した任意フィールドで、無ければ固定契約（8×9 / 192×208）が使われる。
///
/// 推定であることを踏まえて、書いてある場合は必須項目を欠かさないことを要求する。
/// `frames` や `columns` を省いても既定値で動いてしまうと、フィールド名の取り違えが表に出ない。
/// 非オプショナルにしてあるので、欠けていれば復号がそのまま失敗する。
nonisolated struct PetManifest: Decodable, Equatable {
    let id: String
    let displayName: String
    let description: String
    let spritesheetPath: String
    let frame: FrameSpec?
    let animations: [String: AnimationSpec]?

    nonisolated struct FrameSpec: Decodable, Equatable {
        let width: Int
        let height: Int
        let columns: Int
    }

    nonisolated struct AnimationSpec: Decodable, Equatable {
        let frames: [Int]
        let fps: Double?
    }

    static func decode(_ data: Data) throws -> PetManifest {
        try JSONDecoder().decode(PetManifest.self, from: data)
    }

    /// `spritesheetPath` をパッケージ内で解決する。パッケージの外を指すものは受け付けない。
    /// 絶対パスは `relativeTo:` を無視して自身が採用されるので、同じ前方一致で弾ける。
    func spritesheetURL(in packageURL: URL) -> URL? {
        let base = packageURL.standardizedFileURL
        let resolved = URL(fileURLWithPath: spritesheetPath, relativeTo: base).standardizedFileURL

        guard resolved.path.hasPrefix(base.path + "/") else { return nil }
        return resolved
    }
}
