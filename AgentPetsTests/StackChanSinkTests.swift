//
//  StackChanSinkTests.swift
//  AgentPetsTests
//

import AgentPetsCore
import Testing
@testable import AgentPets

@MainActor
final class FakeTransport: RecordTransport {
    var sent: [(display: DisplayState, celebrateSeq: UInt8)] = []
    func send(display: DisplayState, celebrateSeq: UInt8) { sent.append((display, celebrateSeq)) }
}

private func state(_ status: PetStatus, _ subtitle: String = "", celebrate: Bool = false) -> DisplayState {
    DisplayState(status: status, message: "", subtitle: subtitle, sessionKey: nil, celebrate: celebrate)
}

@Suite("StackChanSink")
@MainActor
struct StackChanSinkTests {
    @Test("celebrate のたびに番号が 1 増え、最新の表示状態と一緒に渡る")
    func incrementsOnCelebrate() {
        let transport = FakeTransport()
        let sink = StackChanSink(transport: transport)
        sink.show(state(.success, "demo", celebrate: true))
        sink.show(state(.success, "demo", celebrate: true))
        #expect(transport.sent.map(\.celebrateSeq) == [1, 2])
        #expect(transport.sent.last?.display.subtitle == "demo")
    }

    @Test("celebrate 無しでは番号は増えないが、表示状態は渡る")
    func noCelebrateKeepsSeq() {
        let transport = FakeTransport()
        let sink = StackChanSink(transport: transport)
        sink.show(state(.success, celebrate: true))
        sink.show(state(.working, "Bash · p"))
        sink.show(state(.success, "p"))
        #expect(transport.sent.map(\.celebrateSeq) == [1, 1, 1])
        #expect(transport.sent.last?.display.status == .success)
    }

    @Test("255 の次は 0")
    func wraps() {
        let transport = FakeTransport()
        let sink = StackChanSink(transport: transport)
        for _ in 0..<255 { sink.show(state(.success, celebrate: true)) }
        #expect(sink.celebrateSeq == 255)
        sink.show(state(.success, celebrate: true))
        #expect(sink.celebrateSeq == 0)
        #expect(transport.sent.last?.celebrateSeq == 0)
    }

    @Test("送り先が無い間も最新の値と番号を持ち続け、付けた時点で渡す")
    func keepsLatestWithoutTransport() {
        let sink = StackChanSink()
        sink.show(state(.success, "p", celebrate: true))
        sink.show(state(.waiting, "Bash · p"))
        let transport = FakeTransport()
        sink.transport = transport
        #expect(transport.sent.count == 1)
        #expect(transport.sent.first?.display.status == .waiting)
        #expect(transport.sent.first?.celebrateSeq == 1)
    }

    @Test("送り先を差し替えると、新しい送り先に最新の値と番号を 1 回渡し、古い送り先には送らない")
    func replacesTransport() {
        let old = FakeTransport()
        let sink = StackChanSink(transport: old)
        sink.show(state(.success, "p", celebrate: true))
        sink.show(state(.working, "Bash · p"))
        let new = FakeTransport()
        sink.transport = new
        #expect(old.sent.count == 2)
        #expect(new.sent.count == 1)
        #expect(new.sent.first?.display.status == .working)
        #expect(new.sent.first?.celebrateSeq == 1)
    }
}

/// 複数の sink への配信順を 1 本の記録に残す。
@MainActor
private final class TaggedSink: DisplaySink {
    let tag: String
    let log: (String, DisplayState) -> Void
    init(_ tag: String, log: @escaping (String, DisplayState) -> Void) {
        self.tag = tag
        self.log = log
    }
    func show(_ display: DisplayState) { log(tag, display) }
}

@Suite("FanOutSink")
@MainActor
struct FanOutSinkTests {
    @Test("全 sink に同じ値が同じ順で届く")
    func deliversToAll() {
        // RecordingSink は HubStoreTests.swift で定義済み
        let a = RecordingSink()
        let b = RecordingSink()
        let fanOut = FanOutSink([a, b])
        let first = state(.working, "Bash · p")
        let second = state(.success, "p", celebrate: true)
        fanOut.show(first)
        fanOut.show(second)
        #expect(a.shown == [first, second])
        #expect(b.shown == [first, second])
    }

    @Test("各値を、渡された sink の順に配る")
    func deliversInSinkOrder() {
        var log: [String] = []
        let record: (String, DisplayState) -> Void = { tag, display in log.append("\(tag):\(display.subtitle)") }
        let fanOut = FanOutSink([TaggedSink("pet", log: record), TaggedSink("stackchan", log: record)])
        fanOut.show(state(.working, "1"))
        fanOut.show(state(.success, "2"))
        #expect(log == ["pet:1", "stackchan:1", "pet:2", "stackchan:2"])
    }
}
