import Foundation

/// 吹き出しに描画する文字列の整形。旧 `StatusPayload.sanitize` から移設。
public enum MessageText {
    /// 吹き出しは幅180pt・2行なので、それを大きく超える文字列は切り詰める。
    public static let limit = 120

    public static func sanitize(_ message: String) -> String {
        let collapsed = String(String.UnicodeScalarView(
            message.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : $0 }
        ))
        let trimmed = collapsed
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")

        guard trimmed.count > limit else { return trimmed }
        return trimmed.prefix(limit - 1) + "…"
    }
}
