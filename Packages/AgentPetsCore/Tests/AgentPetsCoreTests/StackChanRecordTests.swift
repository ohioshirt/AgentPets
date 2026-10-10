import Foundation
import Testing
@testable import AgentPetsCore

private func display(_ status: PetStatus, _ subtitle: String) -> DisplayState {
    DisplayState(status: status, message: "吹き出しは送らない", subtitle: subtitle, sessionKey: nil)
}

/// レコードの文の部分（4 バイト目以降）を文字列にする。
private func text(_ data: Data) -> String {
    String(decoding: data.dropFirst(StackChanRecord.headerLength), as: UTF8.self)
}

@Suite("StackChanRecord")
struct StackChanRecordTests {
    @Test("各バイト: 版 1・状態・番号・L・文。吹き出しの文（message）は送らない")
    func bytes() throws {
        let data = try #require(StackChanRecord.encode(display(.waiting, "Bash · uwb"), celebrateSeq: 7, maxLength: 512))
        // "Bash · uwb" は 11 バイト（「·」は U+00B7 で c2 b7）
        #expect(Array(data) == [1, 2, 7, 11] + Array("Bash · uwb".utf8))
    }

    @Test("状態値は idle 0 / working 1 / waiting 2 / success 3 / error 4")
    func statusBytes() throws {
        let expected: [(PetStatus, UInt8)] = [(.idle, 0), (.working, 1), (.waiting, 2), (.success, 3), (.error, 4)]
        for (status, byte) in expected {
            let data = try #require(StackChanRecord.encode(display(status, ""), celebrateSeq: 0, maxLength: 20))
            #expect(Array(data) == [1, byte, 0, 0])
        }
    }

    @Test("番号 255 はそのまま 1 バイトに入る")
    func seq255() throws {
        let data = try #require(StackChanRecord.encode(display(.success, ""), celebrateSeq: 255, maxLength: 20))
        #expect(data[2] == 255)
    }

    @Test("maxLength < 4 なら nil（負の値も）")
    func tooSmall() {
        #expect(StackChanRecord.encode(display(.idle, ""), celebrateSeq: 0, maxLength: 3) == nil)
        #expect(StackChanRecord.encode(display(.idle, ""), celebrateSeq: 0, maxLength: 0) == nil)
        #expect(StackChanRecord.encode(display(.idle, ""), celebrateSeq: 0, maxLength: -1) == nil)
    }

    @Test("ちょうど収まる文は切らない。1 バイト超えると … で終える")
    func exactFit() throws {
        let fits = try #require(StackChanRecord.encode(display(.working, "abcdefghijklmnop"), celebrateSeq: 0, maxLength: 20))
        #expect(fits.count == 20)
        #expect(text(fits) == "abcdefghijklmnop")

        let over = try #require(StackChanRecord.encode(display(.working, "abcdefghijklmnopq"), celebrateSeq: 0, maxLength: 20))
        #expect(over.count == 20)
        #expect(text(over) == "abcdefghijklm…")
        #expect(Int(over[3]) == over.count - 4)
    }

    @Test("マルチバイト: 文字の途中で切らない（最小 MTU の 20 バイト）")
    func multibyte() throws {
        // 「あ」は 3 バイト。16 バイトの枠で … を除く 13 バイトに 4 文字（12 バイト）
        let data = try #require(StackChanRecord.encode(display(.working, "あいうえおかきくけこ"), celebrateSeq: 0, maxLength: 20))
        #expect(text(data) == "あいうえ…")
        #expect(data.count == 19)
        #expect(Int(data[3]) == data.count - 4)
    }

    @Test("絵文字: 肌色修飾つきの 1 文字（8 バイト）を途中で切らない")
    func emoji() throws {
        // "👍🏽" は 1 Character・2 スカラー・8 バイト。文の枠 15 から … を除くと 12 バイトで、
        // スカラー単位で切ると "👍🏽👍"（12 バイト）が入って肌色修飾が外れる
        let data = try #require(StackChanRecord.encode(display(.working, "👍🏽👍🏽"), celebrateSeq: 0, maxLength: 4 + 15))
        #expect(text(data) == "👍🏽…")
        #expect(Int(data[3]) == 11)
    }

    @Test("結合文字: e + U+0301 を分けない")
    func combining() throws {
        // "é"（e + 結合アキュート）は 1 Character・3 バイト。枠 7、… を除く 4 バイトにスカラー単位なら "ée" が入る
        let data = try #require(StackChanRecord.encode(display(.working, "e\u{301}e\u{301}e\u{301}"), celebrateSeq: 0, maxLength: 4 + 7))
        #expect(Array(data.dropFirst(4)) == Array("e\u{301}…".utf8))
    }

    @Test("… も入らない極小の枠では文を空にする。収まる文はそのまま")
    func tinyLimits() throws {
        let four = try #require(StackChanRecord.encode(display(.error, "失敗の詳細"), celebrateSeq: 9, maxLength: 4))
        #expect(Array(four) == [1, 4, 9, 0])

        let six = try #require(StackChanRecord.encode(display(.error, "abc"), celebrateSeq: 9, maxLength: 6))
        #expect(Array(six) == [1, 4, 9, 0])

        let fitsInFive = try #require(StackChanRecord.encode(display(.error, "a"), celebrateSeq: 9, maxLength: 5))
        #expect(Array(fitsInFive) == [1, 4, 9, 1, 0x61])

        let onlyEllipsis = try #require(StackChanRecord.encode(display(.error, "abcd"), celebrateSeq: 9, maxLength: 7))
        #expect(text(onlyEllipsis) == "…")
    }

    @Test("maxLength = 512 で 120 文字の日本語: 全長 259 以下、L は実長と一致、正しい UTF-8")
    func longJapanese() throws {
        let long = MessageText.sanitize(String(repeating: "日本語の文", count: 30))
        #expect(long.count == MessageText.limit)
        let data = try #require(StackChanRecord.encode(display(.waiting, long), celebrateSeq: 1, maxLength: 512))
        #expect(data.count <= StackChanRecord.maxRecordLength)
        #expect(data.count == 259)
        #expect(Int(data[3]) == data.count - 4)
        let body = Array(data.dropFirst(4))
        #expect(String(validating: body, as: UTF8.self) != nil)
        #expect(text(data).hasSuffix("…"))
    }

    @Test("幅の違う文字が混ざっても、入らない文字の後ろを拾わずそこで切る")
    func mixedWidth() throws {
        // 枠 8、… を除く 5 バイト。"abcd" の後の「あ」（3 バイト）は入らない。
        // 飛ばして続けると "abcdx…" になり、文の途中が抜ける
        let data = try #require(StackChanRecord.encode(display(.working, "abcdあxyz"), celebrateSeq: 0, maxLength: 4 + 8))
        #expect(text(data) == "abcd…")
        #expect(Int(data[3]) == 7)
    }

    @Test("1 バイト文字で 255 バイトを超える文: 全長はちょうど 259、L は 255")
    func longAscii() throws {
        let data = try #require(StackChanRecord.encode(display(.working, String(repeating: "a", count: 300)),
                                                       celebrateSeq: 0, maxLength: 512))
        #expect(Array(data) == [1, 1, 0, 255] + Array(repeating: UInt8(ascii: "a"), count: 252) + Array("…".utf8))
    }
}
