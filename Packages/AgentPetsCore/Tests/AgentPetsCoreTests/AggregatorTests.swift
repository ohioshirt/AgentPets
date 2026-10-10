import Testing
@testable import AgentPetsCore

private func table(_ events: [AgentEvent]) -> SessionTable {
    events.reduce(SessionTable()) { SessionReducer.apply($1, to: $0) }
}

private func ev(_ kind: EventKind, _ ts: Double, session: String, source: Source = .claude,
                project: String = "proj", detail: String = "") -> AgentEvent {
    AgentEvent(source: source, session: session, project: project, kind: kind, detail: detail, ts: ts)
}

@Suite("Aggregator")
struct AggregatorTests {
    @Test("セッション 0 件なら idle で文は空")
    func empty() {
        #expect(Aggregator.display(SessionTable()) == .empty)
        #expect(DisplayState.empty.status == .idle)
        #expect(DisplayState.empty.message == "")
    }

    @Test("waiting と working が混在したら waiting")
    func waitingWins() {
        let d = Aggregator.display(table([ev(.turnStarted, 5, session: "a"), ev(.inputRequested, 1, session: "b", detail: "Bash")]))
        #expect(d.status == .waiting)
        #expect(d.sessionKey == SessionKey(source: .claude, session: "b"))
    }

    @Test("優先度は waiting > error > working > success > idle")
    func priorityOrder() {
        #expect(PetStatus.waiting.priority > PetStatus.error.priority)
        #expect(PetStatus.error.priority > PetStatus.working.priority)
        #expect(PetStatus.working.priority > PetStatus.success.priority)
        #expect(PetStatus.success.priority > PetStatus.idle.priority)
    }

    @Test("display でも error > working > success > idle の順に選ぶ（新しさより優先度）")
    func priorityThroughDisplay() {
        // 低い優先度ほど新しい ts にして、「新しいもの優先」の実装では落ちるようにする
        let errorWins = Aggregator.display(table([ev(.turnFailed, 1, session: "e"), ev(.turnStarted, 2, session: "w"),
                                                  ev(.turnCompleted, 3, session: "s")]))
        #expect(errorWins.sessionKey?.session == "e")
        let workingWins = Aggregator.display(table([ev(.turnStarted, 1, session: "w"), ev(.turnCompleted, 2, session: "s")]))
        #expect(workingWins.sessionKey?.session == "w")
        let successWins = Aggregator.display(table([ev(.turnCompleted, 1, session: "s"), ev(.sessionStarted, 2, session: "i")]))
        #expect(successWins.sessionKey?.session == "s")
    }

    @Test("同順位は最終イベントが新しい方")
    func newerWinsTie() {
        let d = Aggregator.display(table([ev(.turnStarted, 1, session: "a"), ev(.turnStarted, 2, session: "b")]))
        #expect(d.sessionKey?.session == "b")
    }

    @Test("A の waiting が TTL で消えると B の working が表示される")
    func stuckWaitingExpires() {
        let t = table([ev(.inputRequested, 0, session: "a", detail: "Bash"), ev(.turnStarted, 1700, session: "b")])
        #expect(Aggregator.display(t).sessionKey?.session == "a")
        let expired = SessionReducer.expire(t, now: 1800)
        #expect(Aggregator.display(expired).sessionKey?.session == "b")
        #expect(Aggregator.display(expired).status == .working)
    }

    @Test("吹き出し文は source・project・状態・detail を含む")
    func message() {
        let d = Aggregator.display(table([ev(.inputRequested, 1, session: "a", project: "uwb", detail: "Bash")]))
        #expect(d.message == "入力待ち (Bash) · uwb")
        #expect(d.tooltip == "claude · uwb: 入力待ち (Bash)")
    }

    @Test("project が空なら source だけ")
    func messageWithoutProject() {
        let d = Aggregator.display(table([ev(.turnStarted, 1, session: "a", source: .codex, project: "")]))
        #expect(d.message == "作業中 · codex")
        #expect(d.tooltip == "codex: 作業中")
    }

    @Test("detail が無ければ括弧なし")
    func messageWithoutDetail() {
        let d = Aggregator.display(table([ev(.turnCompleted, 1, session: "a", project: "demo-project")]))
        #expect(d.message == "完了 · demo-project")
        #expect(d.tooltip == "claude · demo-project: 完了")
    }

    @Test("idle なら文は空")
    func idleMessage() {
        #expect(Aggregator.display(table([ev(.sessionStarted, 1, session: "a")])).message == "")
        #expect(Aggregator.display(table([ev(.sessionStarted, 1, session: "a")])).tooltip == "")
        #expect(DisplayState.empty.tooltip == "")
    }

    @Test("manual は detail をそのまま文にする")
    func manualMessage() {
        let d = Aggregator.display(table([ev(.turnStarted, 1, session: "manual", source: .manual, project: "", detail: "テスト実行中")]))
        #expect(d.message == "テスト実行中")
        #expect(d.tooltip == "テスト実行中")
    }

    @Test("制御文字を含む project と detail でも 1 行に畳む（Review Focus 3）")
    func controlCharacters() {
        let d = Aggregator.display(table([ev(.inputRequested, 1, session: "a", project: "a\nb", detail: "x\ty")]))
        #expect(!d.message.contains("\n"))
        #expect(!d.message.contains("\t"))
    }

    @Test("集約結果は celebrate を立てない")
    func neverCelebrates() {
        let d = Aggregator.display(table([ev(.turnStarted, 1, session: "a"), ev(.turnCompleted, 2, session: "a")]))
        #expect(d.status == .success)
        #expect(d.celebrate == false)
    }

    @Test("sameView は celebrate 以外が同じなら true")
    func sameView() {
        let k = SessionKey(source: .claude, session: "a")
        let x = DisplayState(status: .success, message: "m", sessionKey: k, celebrate: true)
        let y = DisplayState(status: .success, message: "m", sessionKey: k, celebrate: false)
        #expect(x.sameView(as: y))
        #expect(!x.sameView(as: DisplayState(status: .success, message: "n", sessionKey: k, celebrate: false)))
    }

    @Test("sameView は tooltip が違えば false（message が同じでも source が違う場合）")
    func sameViewTooltip() {
        let k = SessionKey(source: .claude, session: "a")
        let x = DisplayState(status: .working, message: "作業中 · p", tooltip: "claude · p: 作業中", sessionKey: k)
        let y = DisplayState(status: .working, message: "作業中 · p", tooltip: "codex · p: 作業中", sessionKey: k)
        #expect(!x.sameView(as: y))
    }
}
