//
//  HubStoreTests.swift
//  AgentPetsTests
//

import AgentPetsCore
import Testing
@testable import AgentPets

@MainActor
final class RecordingSink: DisplaySink {
    var shown: [DisplayState] = []
    func show(_ display: DisplayState) { shown.append(display) }
}

@Suite("HubStore")
@MainActor
struct HubStoreTests {
    @Test("受信したイベントを reducer に通して sink に出す")
    func receives() {
        let sink = RecordingSink()
        let hub = HubStore(sink: sink, clock: { 100 })
        hub.receive(AgentEvent(source: .claude, session: "s", project: "p", kind: .inputRequested, detail: "Bash", ts: 99))
        #expect(sink.shown.last?.status == .waiting)
    }

    @Test("表示中セッションの turn.completed だけが celebrate を立てる")
    func celebratesOnlyDisplayedCompletion() {
        let sink = RecordingSink()
        let hub = HubStore(sink: sink, clock: { 100 })
        hub.receive(AgentEvent(source: .claude, session: "a", project: "p", kind: .turnStarted, ts: 90))
        hub.receive(AgentEvent(source: .claude, session: "a", project: "p", kind: .turnCompleted, ts: 91))
        #expect(sink.shown.last?.celebrate == true)

        // b が waiting で表に出ている間の a の完了は跳ねない
        hub.receive(AgentEvent(source: .claude, session: "b", project: "p", kind: .inputRequested, detail: "Bash", ts: 92))
        hub.receive(AgentEvent(source: .claude, session: "a", project: "p", kind: .turnCompleted, ts: 93))
        #expect(sink.shown.last?.status == .waiting)
        #expect(sink.shown.last?.celebrate == false)
    }

    @Test("Stop 直後の猶予内 activity や tick で同じ見た目を出し直さない（跳ねる動きを打ち切らない）")
    func dedupesSameView() {
        let sink = RecordingSink()
        let hub = HubStore(sink: sink, clock: { 100 })
        hub.receive(AgentEvent(source: .claude, session: "a", project: "p", kind: .turnCompleted, ts: 90))
        let count = sink.shown.count
        hub.receive(AgentEvent(source: .claude, session: "a", project: "p", kind: .activity, detail: "Bash", phase: .post, ts: 90.5))
        // clock は 100 固定なので、この tick で期限切れになるセッションは無い前提
        hub.tick()
        #expect(sink.shown.count == count)
    }

    @Test("捨てられた turn.completed は、同時に他セッションが期限切れになっても跳ねない")
    func droppedCompletionWithExpiryDoesNotCelebrate() {
        let sink = RecordingSink()
        var now = 0.0
        let hub = HubStore(sink: sink, clock: { now })
        hub.receive(AgentEvent(source: .claude, session: "old", project: "p", kind: .inputRequested, detail: "Bash", ts: 0))
        hub.receive(AgentEvent(source: .claude, session: "a", project: "p", kind: .turnCompleted, ts: 1795))
        now = 1800  // old の waiting が TTL 30 分で idle になる時刻
        // a への古い ts（順序保護で捨てられる）の turn.completed
        hub.receive(AgentEvent(source: .claude, session: "a", project: "p", kind: .turnCompleted, ts: 1794))
        #expect(sink.shown.last?.sessionKey?.session == "a")
        #expect(sink.shown.last?.celebrate == false)
    }

    @Test("manual の success は初回も連投も毎回 celebrate")
    func manualSuccessCelebrates() throws {
        let sink = RecordingSink()
        let hub = HubStore(sink: sink, clock: { 0 })
        hub.receive(try #require(WireCodec.decode(#"{"status":"success","message":"完了"}"#, now: 0)))
        #expect(sink.shown.last?.celebrate == true)
        hub.receive(try #require(WireCodec.decode(#"{"status":"success","message":"完了"}"#, now: 0)))
        #expect(sink.shown.last?.celebrate == true)
        #expect(sink.shown.count == 2)
    }

    @Test("tick で TTL が評価される")
    func tickExpires() {
        let sink = RecordingSink()
        var now = 0.0
        let hub = HubStore(sink: sink, clock: { now })
        hub.receive(AgentEvent(source: .claude, session: "s", project: "p", kind: .turnStarted, ts: 0))
        now = 30 * 60
        hub.tick()
        #expect(sink.shown.last?.status == .idle)
    }

    @Test("旧形式の working は 10 秒後の tick で idle（現行挙動の維持）")
    func legacyWorkingTimeout() throws {
        let sink = RecordingSink()
        var now = 0.0
        let hub = HubStore(sink: sink, clock: { now })
        hub.receive(try #require(WireCodec.decode(#"{"status":"working","message":"ビルド中"}"#, now: 0)))
        #expect(sink.shown.last?.status == .working)
        now = 10
        hub.tick()
        #expect(sink.shown.last?.status == .idle)
    }
}
