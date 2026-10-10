import Testing
@testable import AgentPetsCore

@Suite("MessageText.sanitize")
struct MessageTextTests {
    @Test("制御文字を空白に畳んで前後を整える")
    func collapsesControlCharacters() {
        #expect(MessageText.sanitize("\n失敗\tテスト2件\n") == "失敗 テスト2件")
    }

    @Test("長すぎる文字列を120文字で切り詰める")
    func truncates() {
        let long = String(repeating: "あ", count: 500)
        #expect(MessageText.sanitize(long) == String(repeating: "あ", count: 119) + "…")
    }

    @Test("120文字ちょうどは切り詰めない")
    func keepsExactLimit() {
        let exact = String(repeating: "a", count: 120)
        #expect(MessageText.sanitize(exact) == exact)
    }
}
