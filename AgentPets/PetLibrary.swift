//
//  PetLibrary.swift
//  AgentPets
//

import Foundation
import Observation

nonisolated struct Pet: Identifiable, Equatable {
    let id: String
    let displayName: String
    let packageURL: URL
    let manifest: PetManifest
}

/// フォルダ直下からペットパッケージを拾う。
/// ファイルシステムを歩くだけなので `nonisolated` にしてテストから直接呼べるようにしてある。
nonisolated enum PetDiscovery {
    static let manifestName = "pet.json"

    static func pets(in folder: URL) -> [Pet] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return entries.compactMap { entry -> Pet? in
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let data = try? Data(contentsOf: entry.appendingPathComponent(manifestName)),
                  let manifest = try? PetManifest.decode(data) else { return nil }

            return Pet(
                id: manifest.id,
                displayName: manifest.displayName,
                packageURL: entry,
                manifest: manifest
            )
        }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
}

/// security-scoped bookmark の生成と解決。テストで差し替えられるように分けてある。
nonisolated protocol BookmarkResolving {
    func data(for url: URL) throws -> Data
    func url(from data: Data) throws -> (url: URL, isStale: Bool)
}

nonisolated struct SecurityScopedBookmarks: BookmarkResolving {
    func data(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    func url(from data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
    }
}

/// ユーザーが選んだ 1 つのフォルダと、そこにいるペット。
///
/// このアプリはここで設定されたフォルダ以外を見ない。既知の場所を推測して探しに行くことはしない。
@MainActor
@Observable
final class PetLibrary {
    private(set) var pets: [Pet] = []
    private(set) var selection: Pet?
    private(set) var folderURL: URL?
    private(set) var isFolderMissing = false
    private(set) var sheet: SpriteSheet?

    private let defaults: UserDefaults
    private let bookmarks: any BookmarkResolving
    private var accessedURL: URL?

    private enum Key {
        static let bookmark = "petFolderBookmark"
        static let selection = "selectedPetID"
    }

    init(defaults: UserDefaults = .standard, bookmarks: any BookmarkResolving = SecurityScopedBookmarks()) {
        self.defaults = defaults
        self.bookmarks = bookmarks
    }

    /// 起動時に呼ぶ。保存済みの bookmark があれば解決してペットを並べ直す。
    func restore() {
        guard let data = defaults.data(forKey: Key.bookmark) else { return }

        guard let resolved = try? bookmarks.url(from: data) else {
            isFolderMissing = true
            return
        }

        if resolved.isStale, let fresh = try? bookmarks.data(for: resolved.url) {
            defaults.set(fresh, forKey: Key.bookmark)
        }

        adopt(resolved.url)
        if let id = defaults.string(forKey: Key.selection) {
            selection = pets.first { $0.id == id } ?? pets.first
        } else {
            selection = pets.first
        }
        loadSheet(for: selection)
    }

    /// `NSOpenPanel` で選ばれたフォルダを登録する。
    func setFolder(_ url: URL) {
        if let data = try? bookmarks.data(for: url) {
            defaults.set(data, forKey: Key.bookmark)
        }
        adopt(url)
        select(pets.first)
    }

    func select(_ pet: Pet?) {
        selection = pet
        if let pet {
            defaults.set(pet.id, forKey: Key.selection)
        } else {
            defaults.removeObject(forKey: Key.selection)
        }
        loadSheet(for: selection)
    }

    /// 選択中のペットのアトラスを読む。読めなければ nil のままにして、絵文字表示に落とす。
    ///
    /// `adopt(_:)` からは呼ばない。`adopt()` は `selection` を書き換えないので、呼ばれた時点の
    /// `selection` は古いままで、`setFolder` 経路では直後の `select(pets.first)` が正しい読み込みを
    /// 始めてしまう。古い方の完了が後にずれ込むと `sheet` を nil で上書きしかねない。
    private func loadSheet(for pet: Pet?) {
        sheet = nil
        guard let pet, let url = pet.manifest.spritesheetURL(in: pet.packageURL) else { return }

        let frame = pet.manifest.frame
        let id = pet.id
        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                try? SpriteSheet.load(contentsOf: url, frame: frame)
            }.value

            // 読み込んでいる間に選択が変わっていたら捨てる。
            // 先に始めた読み込みが後に終わると、選択とシートが食い違う。
            guard self.selection?.id == id else { return }
            self.sheet = loaded
        }
    }

    /// アクセス権は 1 フォルダにつき 1 回だけ取る。取り直す前に必ず前の分を返す。
    /// 返さずに積み上げるとカーネル資源を漏らし、いずれ Powerbox が使えなくなる。
    private func adopt(_ url: URL) {
        if let accessedURL {
            accessedURL.stopAccessingSecurityScopedResource()
            self.accessedURL = nil
        }
        if url.startAccessingSecurityScopedResource() {
            accessedURL = url
        }

        folderURL = url
        isFolderMissing = false
        pets = PetDiscovery.pets(in: url)
    }
}
