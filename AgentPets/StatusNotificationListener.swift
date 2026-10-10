//
//  StatusNotificationListener.swift
//  AgentPets
//

import AgentPetsCore
import Foundation

/// 外部プロセス（agentpets-hook、agentpets-notify.sh）から届く通知を受け取り、イベントとして渡す。
///
/// HTTP の待ち受けポートを持たないため、ブラウザで開いたページなど
/// アプリ外から到達できる経路が生まれない。ただし同一ログインセッションの
/// 任意のプロセスが同じ通知を投げられる点は変わらないので、
/// 受け取った内容は `WireCodec.decode` で検証してから使う。
@MainActor
final class StatusNotificationListener: NSObject {

    static let notificationName = Notification.Name(WireCodec.notificationName)

    private let onEvent: (AgentEvent) -> Void

    init(onEvent: @escaping (AgentEvent) -> Void) {
        self.onEvent = onEvent
        super.init()
    }

    func start() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleStatusNotification(_:)),
            name: Self.notificationName,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // 配送スレッドを前提にできないので、ペイロードを取り出してから MainActor へ渡す
    @objc private nonisolated func handleStatusNotification(_ notification: Notification) {
        let raw = notification.object as? String
        let now = Date().timeIntervalSince1970
        Task { @MainActor [weak self] in
            guard let self, let event = WireCodec.decode(raw, now: now) else { return }
            self.onEvent(event)
        }
    }
}
