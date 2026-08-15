//
//  StatusPayloadTests.swift
//  AgentPetsTests
//

import Testing
@testable import AgentPets

@Suite("StatusPayload.parse")
struct StatusPayloadTests {

    @Test("有効なJSONからstateとmessageを取り出す")
    func parsesValidPayload() {
        let payload = StatusPayload.parse(#"{"status":"working","message":"ビルド中"}"#)

        #expect(payload?.state == .working)
        #expect(payload?.message == "ビルド中")
    }

    @Test("messageが無いJSONでもstateだけは取り出す")
    func parsesPayloadWithoutMessage() {
        let payload = StatusPayload.parse(#"{"status":"idle"}"#)

        #expect(payload?.state == .idle)
        #expect(payload?.message == "")
    }

    @Test("messageの制御文字を空白に畳んで前後を整える")
    func collapsesControlCharactersInMessage() {
        let payload = StatusPayload.parse(#"{"status":"error","message":"\n失敗\tテスト2件\n"}"#)

        #expect(payload?.message == "失敗 テスト2件")
    }

    @Test("長すぎるmessageを120文字で切り詰める")
    func truncatesOverlongMessage() {
        let long = String(repeating: "あ", count: 500)
        let payload = StatusPayload.parse(#"{"status":"working","message":"\#(long)"}"#)

        #expect(payload?.message.count == 120)
        #expect(payload?.message == String(repeating: "あ", count: 119) + "…")
    }

    @Test("未知のstatusは受け付けない")
    func rejectsUnknownState() {
        #expect(StatusPayload.parse(#"{"status":"pwned","message":"x"}"#) == nil)
    }

    @Test("JSONとして壊れた入力は受け付けない")
    func rejectsMalformedJSON() {
        #expect(StatusPayload.parse("not json at all") == nil)
        #expect(StatusPayload.parse(#"{"status":"#) == nil)
    }

    @Test("文字列が取り出せない通知は受け付けない")
    func rejectsNilInput() {
        #expect(StatusPayload.parse(nil) == nil)
    }
}
