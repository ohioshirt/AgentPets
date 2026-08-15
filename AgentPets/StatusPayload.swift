//
//  StatusPayload.swift
//  AgentPets
//

import Foundation

/// 外部から届いた JSON 文字列を、UI に渡せる状態へ変換した結果。
nonisolated struct StatusPayload {
    let state: PetState
    let message: String

    static func parse(_ raw: String?) -> StatusPayload? {
        guard let raw,
              let data = raw.data(using: .utf8),
              let wire = try? JSONDecoder().decode(Wire.self, from: data),
              let state = PetState(rawValue: wire.status) else { return nil }

        return StatusPayload(state: state, message: sanitize(wire.message ?? ""))
    }

    /// 受け取った文字列はそのまま吹き出しに描画されるので、制御文字を空白に畳んで整える。
    private static func sanitize(_ message: String) -> String {
        let collapsed = String(String.UnicodeScalarView(
            message.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : $0 }
        ))
        let trimmed = collapsed
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")

        guard trimmed.count > messageLimit else { return trimmed }
        return trimmed.prefix(messageLimit - 1) + "…"
    }

    /// 吹き出しは幅180pt・2行なので、それを大きく超える文字列は切り詰める。
    private static let messageLimit = 120

    private struct Wire: Decodable {
        let status: String
        let message: String?
    }
}
