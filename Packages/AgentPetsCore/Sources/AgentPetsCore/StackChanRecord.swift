import Foundation

/// StackChan へ送る状態レコード（wire 版 1）。spec §1.2。
///
/// | バイト | 内容 |
/// |---|---|
/// | 0 | 版（1） |
/// | 1 | 状態（0 idle / 1 working / 2 waiting / 3 success / 4 error） |
/// | 2 | 跳ねる番号（0〜255 で一周） |
/// | 3 | 文のバイト長 L（全長 − 4） |
/// | 4… | 文（UTF-8、`DisplayState.subtitle`） |
public enum StackChanRecord {
    public static let version: UInt8 = 1
    public static let headerLength = 4
    /// L が 1 バイトなので、全長は 4 + 255 = 259 を超えない。
    public static let maxRecordLength = 259
    static let ellipsis = Array("…".utf8)

    public static func statusByte(_ status: PetStatus) -> UInt8 {
        switch status {
        case .idle: return 0
        case .working: return 1
        case .waiting: return 2
        case .success: return 3
        case .error: return 4
        }
    }

    /// 全長は `min(maxLength, 259)` 以下。`maxLength < 4` なら nil。
    /// `maxLength` には `maximumWriteValueLength(for: .withoutResponse)` を渡す。
    public static func encode(_ display: DisplayState, celebrateSeq: UInt8, maxLength: Int) -> Data? {
        let cap = min(maxLength, maxRecordLength)
        guard cap >= headerLength else { return nil }
        let text = fit(display.subtitle, maxBytes: cap - headerLength)
        var data = Data([version, statusByte(display.status), celebrateSeq, UInt8(text.count)])
        data.append(contentsOf: text)
        return data
    }

    /// `Character` の切れ目で、UTF-8 が `maxBytes` に収まるよう切り詰める。
    /// 切ったときは末尾を `…`（3 バイト）にする。`…` すら入らないときは空にする。
    static func fit(_ text: String, maxBytes: Int) -> [UInt8] {
        let whole = Array(text.utf8)
        if whole.count <= maxBytes { return whole }
        guard maxBytes >= ellipsis.count else { return [] }
        let budget = maxBytes - ellipsis.count
        var kept: [UInt8] = []
        for character in text {
            let bytes = Array(String(character).utf8)
            if kept.count + bytes.count > budget { break }
            kept += bytes
        }
        return kept + ellipsis
    }
}
