//
//  PetLibraryTests.swift
//  AgentPetsTests
//

import Foundation
import Testing
@testable import AgentPets

@Suite("PetDiscovery")
struct PetDiscoveryTests {

    private func makeFolder() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makePackage(in folder: URL, id: String) throws {
        let package = folder.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("""
        {
          "id": "\(id)", "displayName": "\(id.capitalized)",
          "description": "d", "spritesheetPath": "spritesheet.webp"
        }
        """.utf8).write(to: package.appendingPathComponent("pet.json"))
    }

    @Test("pet.jsonを持つディレクトリを拾う")
    func findsPackages() throws {
        let folder = try makeFolder()
        try makePackage(in: folder, id: "zundamon")
        try makePackage(in: folder, id: "moka")

        let pets = PetDiscovery.pets(in: folder)

        #expect(pets.map(\.id).sorted() == ["moka", "zundamon"])
        #expect(pets.map(\.packageURL.lastPathComponent).sorted() == ["moka", "zundamon"])
    }

    @Test("pet.jsonを持たないディレクトリは拾わない")
    func skipsDirectoriesWithoutManifest() throws {
        let folder = try makeFolder()
        try makePackage(in: folder, id: "zundamon")
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("empty", isDirectory: true),
            withIntermediateDirectories: true
        )

        #expect(PetDiscovery.pets(in: folder).map(\.id) == ["zundamon"])
    }

    @Test("直下のファイルは拾わない")
    func skipsPlainFiles() throws {
        let folder = try makeFolder()
        try makePackage(in: folder, id: "zundamon")
        try Data("x".utf8).write(to: folder.appendingPathComponent("README.txt"))
        try Data("{}".utf8).write(to: folder.appendingPathComponent("pet.json"))

        #expect(PetDiscovery.pets(in: folder).map(\.id) == ["zundamon"])
    }

    @Test("2階層目は拾わない")
    func doesNotRecurse() throws {
        let folder = try makeFolder()
        let nested = folder.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try makePackage(in: nested, id: "deep")

        #expect(PetDiscovery.pets(in: folder).isEmpty)
    }

    @Test("壊れたpet.jsonのディレクトリは飛ばして続ける")
    func skipsBrokenManifest() throws {
        let folder = try makeFolder()
        try makePackage(in: folder, id: "zundamon")
        let broken = folder.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: broken.appendingPathComponent("pet.json"))

        #expect(PetDiscovery.pets(in: folder).map(\.id) == ["zundamon"])
    }

    @Test("存在しないフォルダでは空を返す")
    func returnsEmptyForMissingFolder() {
        let missing = URL(fileURLWithPath: "/tmp/definitely-not-here-\(UUID().uuidString)")

        #expect(PetDiscovery.pets(in: missing).isEmpty)
    }

    @Test("表示名の順に並べる")
    func sortsByDisplayName() throws {
        let folder = try makeFolder()
        for id in ["zundamon", "aria", "moka"] { try makePackage(in: folder, id: id) }

        #expect(PetDiscovery.pets(in: folder).map(\.id) == ["aria", "moka", "zundamon"])
    }

    @Test("idが空のパッケージは拾わない")
    func skipsEmptyIdPackage() throws {
        let folder = try makeFolder()
        try makePackage(in: folder, id: "zundamon")
        let empty = folder.appendingPathComponent("empty-id", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data("""
        {
          "id": "", "displayName": "Empty",
          "description": "d", "spritesheetPath": "spritesheet.webp"
        }
        """.utf8).write(to: empty.appendingPathComponent("pet.json"))

        #expect(PetDiscovery.pets(in: folder).map(\.id) == ["zundamon"])
    }
}

@Suite("PetLibrary")
@MainActor
struct PetLibraryTests {

    /// 本番の bookmark は NSOpenPanel が付与した URL にしか作れないので、
    /// 保存と解決の経路だけを差し替えて確かめる。
    private final class FakeBookmarks: BookmarkResolving {
        var stored: [Data: URL] = [:]
        var isStale = false
        private var generation = 0

        func data(for url: URL) throws -> Data {
            generation += 1
            let data = Data("\(url.path)#\(generation)".utf8)
            stored[data] = url
            return data
        }

        // タプルのラベルは型の一部で、外すと適合しない。protocol と同じ形で書く。
        func url(from data: Data) throws -> (url: URL, isStale: Bool) {
            guard let url = stored[data] else { throw CocoaError(.fileNoSuchFile) }
            return (url, isStale)
        }
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "PetLibraryTests-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    @Test("フォルダを設定するとペットが並ぶ")
    func listsPetsAfterSettingFolder() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lib-\(UUID().uuidString)", isDirectory: true)
        let package = folder.appendingPathComponent("zundamon", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("""
        { "id": "zundamon", "displayName": "Zundamon",
          "description": "d", "spritesheetPath": "spritesheet.webp" }
        """.utf8).write(to: package.appendingPathComponent("pet.json"))

        let library = PetLibrary(defaults: makeDefaults(), bookmarks: FakeBookmarks())
        library.setFolder(folder)

        #expect(library.pets.map(\.id) == ["zundamon"])
        #expect(library.folderURL == folder)
    }

    @Test("選択したペットを覚えて復元する")
    func restoresSelection() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lib-\(UUID().uuidString)", isDirectory: true)
        for id in ["zundamon", "moka"] {
            let package = folder.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            try Data("""
            { "id": "\(id)", "displayName": "\(id)",
              "description": "d", "spritesheetPath": "spritesheet.webp" }
            """.utf8).write(to: package.appendingPathComponent("pet.json"))
        }

        let defaults = makeDefaults()
        let bookmarks = FakeBookmarks()

        let first = PetLibrary(defaults: defaults, bookmarks: bookmarks)
        first.setFolder(folder)
        first.select(first.pets.first { $0.id == "moka" })
        #expect(first.selection?.id == "moka")

        let second = PetLibrary(defaults: defaults, bookmarks: bookmarks)
        second.restore()

        #expect(second.folderURL == folder)
        #expect(second.selection?.id == "moka")
    }

    @Test("フォルダ未設定なら空のまま")
    func staysEmptyWithoutFolder() {
        let library = PetLibrary(defaults: makeDefaults(), bookmarks: FakeBookmarks())
        library.restore()

        #expect(library.folderURL == nil)
        #expect(library.pets.isEmpty)
        #expect(library.selection == nil)
    }

    @Test("解決できない bookmark は見つからない扱いにする")
    func reportsMissingFolder() throws {
        let defaults = makeDefaults()
        let bookmarks = FakeBookmarks()
        let folder = URL(fileURLWithPath: "/tmp/gone-\(UUID().uuidString)", isDirectory: true)

        let first = PetLibrary(defaults: defaults, bookmarks: bookmarks)
        first.setFolder(folder)

        bookmarks.stored.removeAll()
        let second = PetLibrary(defaults: defaults, bookmarks: bookmarks)
        second.restore()

        #expect(second.folderURL == nil)
        #expect(second.isFolderMissing)
    }

    @Test("staleなbookmarkを作り直して保存し直す")
    func refreshesStaleBookmark() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lib-\(UUID().uuidString)", isDirectory: true)
        let package = folder.appendingPathComponent("zundamon", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("""
        { "id": "zundamon", "displayName": "Zundamon",
          "description": "d", "spritesheetPath": "spritesheet.webp" }
        """.utf8).write(to: package.appendingPathComponent("pet.json"))

        let defaults = makeDefaults()
        let bookmarks = FakeBookmarks()

        let first = PetLibrary(defaults: defaults, bookmarks: bookmarks)
        first.setFolder(folder)
        let original = try #require(defaults.data(forKey: "petFolderBookmark"))

        bookmarks.isStale = true
        let second = PetLibrary(defaults: defaults, bookmarks: bookmarks)
        second.restore()

        let refreshed = try #require(defaults.data(forKey: "petFolderBookmark"))
        #expect(refreshed != original, "staleなbookmarkが作り直されていない")
        #expect(second.folderURL == folder)
        #expect(second.isFolderMissing == false)
        #expect(second.pets.isEmpty == false)
    }

    @Test("絵文字で表示を選んで再起動しても絵文字のまま")
    func preservesEmojiSelection() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lib-\(UUID().uuidString)", isDirectory: true)
        let package = folder.appendingPathComponent("zundamon", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("""
        { "id": "zundamon", "displayName": "Zundamon",
          "description": "d", "spritesheetPath": "spritesheet.webp" }
        """.utf8).write(to: package.appendingPathComponent("pet.json"))

        let defaults = makeDefaults()
        let bookmarks = FakeBookmarks()

        let first = PetLibrary(defaults: defaults, bookmarks: bookmarks)
        first.setFolder(folder)
        first.select(nil)  // Select emoji mode
        #expect(first.selection == nil)

        let second = PetLibrary(defaults: defaults, bookmarks: bookmarks)
        second.restore()

        #expect(second.selection == nil, "絵文字表示が保存されていない")
    }

    @Test("フォールバックで選ばれたペットが保存される")
    func savesSelectedPetFromFallback() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lib-\(UUID().uuidString)", isDirectory: true)
        for id in ["zundamon", "moka"] {
            let package = folder.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            try Data("""
            { "id": "\(id)", "displayName": "\(id)",
              "description": "d", "spritesheetPath": "spritesheet.webp" }
            """.utf8).write(to: package.appendingPathComponent("pet.json"))
        }

        let defaults = makeDefaults()
        let bookmarks = FakeBookmarks()

        // Simulate selection saved as invalid pet ID
        let first = PetLibrary(defaults: defaults, bookmarks: bookmarks)
        first.setFolder(folder)
        defaults.set("invalid-pet-id", forKey: "selectedPetID")

        let second = PetLibrary(defaults: defaults, bookmarks: bookmarks)
        second.restore()

        // Should fall back to first pet and save it
        #expect(second.selection != nil)
        #expect(defaults.string(forKey: "selectedPetID") == second.selection?.id)
    }

    @Test("0匹のフォルダを登録しても選択キーを書かない")
    func doesNotWriteSelectionForEmptyFolder() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lib-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let defaults = makeDefaults()
        let bookmarks = FakeBookmarks()

        let library = PetLibrary(defaults: defaults, bookmarks: bookmarks)
        library.setFolder(folder)

        #expect(defaults.string(forKey: "selectedPetID") == nil)
        #expect(library.selection == nil)
    }
}
