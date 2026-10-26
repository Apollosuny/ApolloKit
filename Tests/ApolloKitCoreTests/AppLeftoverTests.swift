import Foundation
import Testing
@testable import ApolloKitCore

@Suite struct AppLeftoverTests {
    private let largeFile = 2_000_000

    private func makeApp(_ tree: TemporaryTree, _ name: String, bundleID: String) throws {
        let contents = try tree.directory("Applications/\(name).app/Contents")
        let info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": name]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    private func makeElectronData(_ tree: TemporaryTree, _ folder: String) throws {
        try tree.file("Library/Application Support/\(folder)/Local Storage/leveldb/000003.log")
        try tree.file("Library/Application Support/\(folder)/Preferences")
        try tree.file("Library/Application Support/\(folder)/User/state.vscdb", bytes: largeFile)
    }

    /// Everything created so far looks untouched for two months.
    private func ageAllFiles(in tree: TemporaryTree) throws {
        let old = Date.now.addingTimeInterval(-60 * 24 * 60 * 60)
        let enumerator = try #require(FileManager.default.enumerator(at: tree.root, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
    }

    @Test func reportsDataOfRemovedAppsButNotOfInstalledAppsOrTools() async throws {
        let tree = try TemporaryTree()
        try makeApp(tree, "Zalo", bundleID: "com.vng.zalo")
        try makeApp(tree, "Raycast", bundleID: "com.raycast.macos")

        try makeElectronData(tree, "Cursor")
        try tree.file("Library/Application Support/Cursor/CachedData/abc/bundle.js", bytes: largeFile)
        try tree.file("Library/Containers/com.example.gonechat/Data/Library/db.sqlite", bytes: largeFile)
        // The installed Zalo app names its data folder after itself plus a suffix.
        try makeElectronData(tree, "ZaloData")
        // Shared data of an installed vendor's app stays; a sandbox container is only ever its own app's.
        try tree.file("Library/Application Support/com.raycast.shared/extensions.db", bytes: largeFile)
        try tree.file("Library/Containers/com.raycast.oldnotes/Data/notes.db", bytes: largeFile)
        try tree.file("Library/Application Support/com.apple.sharedfilelist/list.sfl", bytes: largeFile)
        try tree.file("Library/Application Support/virtualenv/wheel/cache.whl", bytes: largeFile)
        try tree.file("Library/Containers/com.example.tiny/Data/prefs", bytes: 100)
        try tree.file("Library/HTTPStorages/com.example.recent/httpstorages.sqlite", bytes: 0)
        try ageAllFiles(in: tree)
        try tree.file("Library/HTTPStorages/com.example.recent/httpstorages.sqlite", bytes: largeFile)
        // Another program reading the database rewrites only its shared-memory file.
        try tree.file("Library/Application Support/Cursor/User/state.vscdb-shm")

        let report = try await DiskScanner(
            homeDirectory: tree.root,
            tools: ToolEnvironment(runner: FakeToolRunner([:]), xcrun: nil, docker: nil),
            applicationDirectories: [tree.url("Applications")]
        ).scan(enabledRuleIDs: ["apps.leftovers", "editor.vscode"], projectRoots: [])

        // The editor cache rule's Cursor/CachedData is part of the leftover, not a second item.
        #expect(report.items.map(\.displayName).sorted() == [
            "Application Support › Cursor",
            "Containers › com.example.gonechat",
            "Containers › com.raycast.oldnotes",
        ])
        #expect(report.items.allSatisfy { $0.risk == .caution })
    }

    @Test func appsInstalledOutsideTheApplicationFoldersKeepTheirData() throws {
        let tree = try TemporaryTree()
        try tree.file("Library/Containers/com.example.portable.helper/Data/db.sqlite", bytes: largeFile)
        try ageAllFiles(in: tree)

        let finder = AppLeftoverFinder(homeDirectory: tree.root, installedApps: []) { $0 == "com.example.portable" }
        #expect(finder.find().isEmpty)
    }
}
