//
//  StatusNotificationListener.swift
//  AgentPets
//

import Foundation

/// 外部プロセス（Claude Code のフック等）から届く状態通知を受け取り、UI に反映する。
///
/// HTTP の待ち受けポートを持たないため、ブラウザで開いたページなど
/// アプリ外から到達できる経路が生まれない。ただし同一ログインセッションの
/// 任意のプロセスが同じ通知を投げられる点は変わらないので、
/// 受け取った内容は `StatusPayload.parse` で検証してから使う。
@MainActor
final class StatusNotificationListener: NSObject {

    /// バンドルIDがまだプレースホルダなので、それとは独立した固定名にしている。
    static let notificationName = Notification.Name("com.agentpets.status")

    private let viewModel: PetViewModel

    init(viewModel: PetViewModel) {
        self.viewModel = viewModel
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
        Task { @MainActor [weak self] in
            guard let self, let payload = StatusPayload.parse(raw) else { return }
            self.viewModel.apply(payload)
        }
    }
}
