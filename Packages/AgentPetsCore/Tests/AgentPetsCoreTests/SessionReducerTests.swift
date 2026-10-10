import Testing
@testable import AgentPetsCore

private func ev(_ kind: EventKind, _ ts: Double, session: String = "s", source: Source = .claude,
                detail: String = "", phase: ActivityPhase? = nil) -> AgentEvent {
    AgentEvent(source: source, session: session, project: "p", kind: kind, detail: detail, phase: phase, ts: ts)
}

private func run(_ events: [AgentEvent], config: ReducerConfig = .init()) -> SessionTable {
    events.reduce(SessionTable()) { SessionReducer.apply($1, to: $0, config: config) }
}

private func status(_ t: SessionTable, _ session: String = "s", _ source: Source = .claude) -> PetStatus? {
    t.sessions[SessionKey(source: source, session: session)]?.status
}

@Suite("SessionReducer.apply")
struct SessionReducerApplyTests {
    @Test("基本の遷移", arguments: [
        (EventKind.turnStarted, PetStatus.working),
        (.inputRequested, .waiting),
        (.turnCompleted, .success),
        (.turnFailed, .error),
        (.turnInterrupted, .idle),
    ])
    func basic(kind: EventKind, expected: PetStatus) {
        #expect(status(run([ev(.turnStarted, 1), ev(kind, 10)])) == expected)
    }

    @Test("新規セッションの session.started は idle で作る")
    func startedCreatesIdle() {
        #expect(status(run([ev(.sessionStarted, 1)])) == .idle)
    }

    @Test("manual の detail は遷移後も保たれる")
    func manualDetailKept() {
        let t = run([ev(.turnStarted, 1, session: "manual", source: .manual, detail: "テスト実行中")])
        #expect(t.sessions[SessionKey(source: .manual, session: "manual")]?.detail == "テスト実行中")
    }

    @Test("session.ended で削除")
    func ended() {
        #expect(run([ev(.turnStarted, 1), ev(.sessionEnded, 2)]).sessions.isEmpty)
    }

    @Test("既存セッションへの session.started は状態を変えない（resume）")
    func resumeKeepsState() {
        #expect(status(run([ev(.turnStarted, 1), ev(.sessionStarted, 2)])) == .working)
    }

    @Test("最後に適用した ts より古いイベントは捨てる")
    func dropsOlder() {
        #expect(status(run([ev(.turnCompleted, 10), ev(.turnStarted, 9)])) == .success)
    }

    @Test("10 秒を超えて古いイベントは時計の変化とみなして受け入れ、以後はその時刻を基準にする（Review Focus 1）")
    func acceptsClockJump() {
        let t = run([ev(.turnCompleted, 1000), ev(.turnStarted, 900)])
        #expect(status(t) == .working)
        #expect(t.sessions[SessionKey(source: .claude, session: "s")]?.lastAppliedTS == 900)
        // 巻き戻った時計の上で、直後のイベントが落ちず、TTL も効く
        #expect(status(run([ev(.turnCompleted, 1000), ev(.turnStarted, 900), ev(.inputRequested, 995)])) == .waiting)
        #expect(status(SessionReducer.expire(t, now: 900 + 30 * 60)) == .idle)
    }

    @Test("waiting と error は turn.started で working に戻る", arguments: [EventKind.inputRequested, .turnFailed])
    func turnStartedExits(kind: EventKind) {
        #expect(status(run([ev(kind, 10, detail: "Bash"), ev(.turnStarted, 11)])) == .working)
    }

    @Test("同じ ts のイベントは受け入れる")
    func acceptsEqualTS() {
        #expect(status(run([ev(.turnStarted, 10), ev(.inputRequested, 10, detail: "Bash")])) == .waiting)
    }

    @Test("input.requested の 0.5 秒後の activity は捨て、2 秒後の一致する post activity で working")
    func graceAfterWaiting() {
        let base = [ev(.turnStarted, 1), ev(.inputRequested, 10, detail: "Bash")]
        #expect(status(run(base + [ev(.activity, 10.5, detail: "Bash", phase: .pre)])) == .waiting)
        #expect(status(run(base + [ev(.activity, 12, detail: "Bash", phase: .post)])) == .working)
    }

    @Test("turn.completed の 0.5 秒後の activity で success が working に戻らない")
    func graceAfterSuccess() {
        #expect(status(run([ev(.turnCompleted, 10), ev(.activity, 10.5, detail: "Bash", phase: .post)])) == .success)
    }

    @Test("turn.failed の猶予後の activity で working")
    func errorExitsByActivity() {
        #expect(status(run([ev(.turnFailed, 10), ev(.activity, 12, detail: "Bash", phase: .pre)])) == .working)
    }

    @Test("waiting(Bash) 中に別ツール Read の post activity が 2 秒後に来ても waiting")
    func waitingIgnoresOtherTool() {
        let t = run([ev(.inputRequested, 10, detail: "Bash"), ev(.activity, 12, detail: "Read", phase: .post)])
        #expect(status(t) == .waiting)
    }

    @Test("waiting(Bash) 中に同じツールの pre activity は waiting のまま")
    func waitingIgnoresPre() {
        let t = run([ev(.inputRequested, 10, detail: "Bash"), ev(.activity, 12, detail: "Bash", phase: .pre)])
        #expect(status(t) == .waiting)
    }

    @Test("detail が空の waiting は任意の activity（猶予後）で抜ける")
    func emptyDetailWaitingExits() {
        let t = run([ev(.inputRequested, 10), ev(.activity, 12, detail: "Read", phase: .pre)])
        #expect(status(t) == .working)
    }

    @Test("waiting 中に detail 空の input.requested が来ても detail を保ち、猶予の起点を取り直す")
    func reentryKeepsDetailAndResetsGrace() {
        let t = run([ev(.inputRequested, 10, detail: "Bash"), ev(.inputRequested, 16)])
        let s = t.sessions[SessionKey(source: .claude, session: "s")]
        #expect(s?.detail == "Bash")
        #expect(s?.enteredTS == 16)
        // 起点 16 から 0.5 秒後の一致 post は猶予内なので捨てる
        #expect(status(run([ev(.inputRequested, 10, detail: "Bash"), ev(.inputRequested, 16),
                            ev(.activity, 16.5, detail: "Bash", phase: .post)])) == .waiting)
    }

    @Test("捨てた activity は最終 ts を進めない")
    func droppedDoesNotAdvanceTS() {
        let t = run([ev(.inputRequested, 10, detail: "Bash"), ev(.activity, 10.5, detail: "Bash", phase: .post)])
        #expect(t.sessions[SessionKey(source: .claude, session: "s")]?.lastAppliedTS == 10)
    }

    @Test("agent.idle は waiting / working を idle にし、success / error は変えない", arguments: [
        (EventKind.inputRequested, PetStatus.idle),
        (.turnStarted, .idle),
        (.turnCompleted, .success),
        (.turnFailed, .error),
    ])
    func agentIdle(before: EventKind, expected: PetStatus) {
        #expect(status(run([ev(before, 10), ev(.agentIdle, 70)])) == expected)
    }

    @Test("中断（以降イベントなし）→ agent.idle で waiting が解ける")
    func interruptedThenIdlePrompt() {
        #expect(status(run([ev(.turnStarted, 1), ev(.inputRequested, 5, detail: "Bash"), ev(.agentIdle, 65)])) == .idle)
    }

    @Test("turn.completed で completionCount が増える")
    func completionCount() {
        let t = run([ev(.turnStarted, 1), ev(.turnCompleted, 2), ev(.turnStarted, 3), ev(.turnCompleted, 4)])
        #expect(t.sessions[SessionKey(source: .claude, session: "s")]?.completionCount == 2)
    }

    @Test("起動前から続くセッションの最初のイベントが activity なら working で作る（Review Focus 4）")
    func unknownSessionActivity() {
        #expect(status(run([ev(.activity, 5, detail: "Bash", phase: .post)])) == .working)
    }

    @Test("source が違えば同じ session_id でも別セッション")
    func separatesBySource() {
        let t = run([ev(.turnStarted, 1, source: .claude), ev(.inputRequested, 2, source: .codex)])
        #expect(status(t, "s", .claude) == .working)
        #expect(status(t, "s", .codex) == .waiting)
    }
}

@Suite("SessionReducer.expire")
struct SessionReducerExpireTests {
    let minute = 60.0

    @Test("working は 29 分無音では working、30 分で idle")
    func workingTTL() {
        let t = run([ev(.turnStarted, 0)])
        #expect(status(SessionReducer.expire(t, now: 29 * minute)) == .working)
        #expect(status(SessionReducer.expire(t, now: 30 * minute)) == .idle)
    }

    @Test("waiting と error は 30 分で idle", arguments: [EventKind.inputRequested, .turnFailed])
    func waitingErrorTTL(kind: EventKind) {
        let t = run([ev(kind, 0)])
        #expect(status(SessionReducer.expire(t, now: 30 * minute)) == .idle)
    }

    @Test("success は 30 分では残り、2 時間で削除")
    func successTTL() {
        let t = run([ev(.turnCompleted, 0)])
        #expect(status(SessionReducer.expire(t, now: 30 * minute)) == .success)
        #expect(SessionReducer.expire(t, now: 120 * minute).sessions.isEmpty)
    }

    @Test("どの状態も 2 時間無音で削除")
    func sessionTTL() {
        let t = run([ev(.sessionStarted, 0)])
        #expect(SessionReducer.expire(t, now: 120 * minute).sessions.isEmpty)
    }

    @Test("manual の working は 10 秒で idle、それ以外は 10 分で削除")
    func manualTTL() {
        let working = run([ev(.turnStarted, 0, session: "manual", source: .manual)])
        #expect(status(SessionReducer.expire(working, now: 9.9), "manual", .manual) == .working)
        #expect(status(SessionReducer.expire(working, now: 10), "manual", .manual) == .idle)
        let waiting = run([ev(.inputRequested, 0, session: "manual", source: .manual)])
        #expect(status(SessionReducer.expire(waiting, now: 9 * minute), "manual", .manual) == .waiting)
        #expect(SessionReducer.expire(waiting, now: 10 * minute).sessions.isEmpty)
    }
}
