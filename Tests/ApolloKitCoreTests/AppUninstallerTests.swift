import Foundation
import Testing
@testable import ApolloKitCore

@Suite struct AppUninstallerTests {
    @discardableResult
    private func makeApp(_ tree: TemporaryTree, _ path: String, bundleID: String, name: String) throws -> URL {
        let contents = try tree.directory("\(path)/Contents")
        let info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": name, "CFBundleShortVersionString": "2.1"]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        try tree.file("\(path)/Contents/MacOS/\(name)", bytes: 4_096)
        return tree.url(path)
    }

    private func uninstaller(_ tree: TemporaryTree) -> AppUninstaller {
        AppUninstaller(homeDirectory: tree.root, applicationDirectories: [tree.url("Applications")])
    }

    @Test func listsAppsIncludingOneFolderLevelDeep() throws {
        let tree = try TemporaryTree()
        try makeApp(tree, "Applications/Foo.app", bundleID: "com.example.foo", name: "Foo")
        try makeApp(tree, "Applications/Setapp/Bar.app", bundleID: "com.example.bar", name: "Bar")
        try makeApp(tree, "Applications/Safari.app", bundleID: "com.apple.Safari", name: "Safari")

        let apps = uninstaller(tree).installedApps()
        #expect(apps.map(\.name) == ["Bar", "Foo", "Safari"])
        #expect(apps.first { $0.name == "Foo" }?.version == "2.1")
        #expect(apps.filter(\.isSystemApp).map(\.name) == ["Safari"])
    }

    @Test func findsDataByBundleIdentifierAndFlagsNameMatches() throws {
        let tree = try TemporaryTree()
        try makeApp(tree, "Applications/Foo.app", bundleID: "com.example.foo", name: "Foo")
        try tree.file("Library/Application Support/com.example.foo/db.sqlite")
        try tree.file("Library/Caches/com.example.foo/cache.bin")
        try tree.file("Library/Preferences/com.example.foo.plist")
        try tree.file("Library/Group Containers/TEAM123.com.example.foo/shared.db")
        try tree.file("Library/Containers/com.example.foo.widget/Data/a")
        try tree.file("Library/Application Support/Foo/settings.json")
        try tree.file("Library/Caches/com.example.foobar/unrelated")
        try tree.file("Library/Preferences/com.example.foo.pro.plist")

        let app = try #require(uninstaller(tree).installedApps().first)
        let items = uninstaller(tree).footprint(of: app, otherBundleIdentifiers: ["com.example.foo.pro"])
        let ruleByName = Dictionary(uniqueKeysWithValues: items.map { ($0.displayName, $0.rule.id) })

        #expect(ruleByName == [
            "Foo.app": "uninstall.application",
            "Application Support › com.example.foo": "uninstall.appData",
            "Caches › com.example.foo": "uninstall.appData",
            "Preferences › com.example.foo.plist": "uninstall.appData",
            "Group Containers › TEAM123.com.example.foo": "uninstall.appData",
            "Containers › com.example.foo.widget": "uninstall.appData",
            "Application Support › Foo": "uninstall.possiblyRelated",
        ])
        #expect(items.first { $0.rule == AppUninstaller.Rules.possiblyRelated }?.rule.risk == .caution)
    }

    @Test(arguments: [
        ("com.google.Chrome", true),
        ("com.google.Chrome.plist", true),
        ("EQHXZ8M8AV.com.google.Chrome", true),
        ("com.google.Chrome.canary", false),
        ("com.google.Chrome.canary.plist", false),
        ("com.google.Chromeless", false),
    ])
    func relatedAppsKeepTheirData(entry: String, belongs: Bool) {
        #expect(AppUninstaller.belongs(entry, to: "com.google.Chrome", others: ["com.google.Chrome.canary"]) == belongs)
    }

    @Test func appBundleOutsideHomeIsAllowedOnlyWithItsFolderAsRoot() throws {
        let tree = try TemporaryTree()
        let app = try makeApp(tree, "Applications/Foo.app", bundleID: "com.example.foo", name: "Foo")
        let home = try tree.directory("home")

        #expect(throws: SafetyPolicy.Violation.self) { try SafetyPolicy(homeDirectory: home).validate(app) }
        let policy = SafetyPolicy(homeDirectory: home, additionalAllowedRoots: [app.deletingLastPathComponent()])
        try policy.validate(app)
        #expect(throws: SafetyPolicy.Violation.self) { try policy.validate(app.deletingLastPathComponent()) }
    }
}
