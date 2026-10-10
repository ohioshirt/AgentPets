import Foundation
import Testing
@testable import AgentPetsCore

@Suite("WireCodec")
struct WireCodecTests {
    let sample = AgentEvent(source: .claude, session: "s1", project: "demo",
                            kind: .activity, detail: "Bash", phase: .pre, ts: 100.5)

    @Test("v2 は encode して decode すると元に戻る")
    func roundTrips() throws {
        let raw = try #require(WireCodec.encode(sample))
        #expect(raw.contains(#""v":2"#))
        #expect(WireCodec.decode(raw, now: 999) == sample)
    }

    @Test("v2 の未知の kind は受け付けない")
    func rejectsUnknownKind() {
        let raw = #"{"v":2,"source":"claude","session":"s","project":"","kind":"pwned","detail":"","ts":1}"#
        #expect(WireCodec.decode(raw, now: 1) == nil)
    }

    @Test("v2 の未知の source は受け付けない")
    func rejectsUnknownSource() {
        let raw = #"{"v":2,"source":"evil","session":"s","project":"","kind":"activity","detail":"","ts":1}"#
        #expect(WireCodec.decode(raw, now: 1) == nil)
    }

    @Test("v が 2 以外は受け付けない")
    func rejectsOtherVersion() {
        let raw = #"{"v":3,"source":"claude","session":"s","project":"","kind":"activity","detail":"","ts":1}"#
        #expect(WireCodec.decode(raw, now: 1) == nil)
    }

    @Test("旧形式の各 status を manual イベントに変換する",
          arguments: [
            ("idle", EventKind.turnInterrupted),
            ("working", .turnStarted),
            ("waiting", .inputRequested),
            ("success", .turnCompleted),
            ("error", .turnFailed),
          ])
    func convertsLegacy(status: String, kind: EventKind) throws {
        let event = try #require(WireCodec.decode(#"{"status":"\#(status)","message":"ビルド中"}"#, now: 42))
        #expect(event.source == .manual)
        #expect(event.session == "manual")
        #expect(event.kind == kind)
        #expect(event.detail == "ビルド中")
        #expect(event.ts == 42)
    }

    @Test("旧形式で message が無くても受け付ける")
    func legacyWithoutMessage() {
        #expect(WireCodec.decode(#"{"status":"idle"}"#, now: 1)?.detail == "")
    }

    @Test("旧形式の message も整形する")
    func legacySanitizes() {
        #expect(WireCodec.decode(#"{"status":"error","message":"\n失敗\tテスト2件\n"}"#, now: 1)?.detail == "失敗 テスト2件")
    }

    @Test("旧形式の未知の status は受け付けない")
    func legacyRejectsUnknown() {
        #expect(WireCodec.decode(#"{"status":"pwned","message":"x"}"#, now: 1) == nil)
    }

    @Test("壊れた入力と nil は受け付けない")
    func rejectsMalformed() {
        #expect(WireCodec.decode("not json at all", now: 1) == nil)
        #expect(WireCodec.decode(#"{"status":"#, now: 1) == nil)
        #expect(WireCodec.decode(nil, now: 1) == nil)
    }

    @Test("v2 の detail と project も受信側で整形する")
    func sanitizesV2Fields() throws {
        let raw = #"{"v":2,"source":"claude","session":"s","project":"a\nb","kind":"activity","detail":"x\ty","ts":1}"#
        let event = try #require(WireCodec.decode(raw, now: 1))
        #expect(event.project == "a b")
        #expect(event.detail == "x y")
    }
}
