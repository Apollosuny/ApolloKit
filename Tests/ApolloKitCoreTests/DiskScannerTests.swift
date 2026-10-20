import Foundation
import Testing
@testable import ApolloKitCore

@Suite struct DiskScannerTests {
    private func scan(_ tree: TemporaryTree, ruleIDs: Set<String>, roots: [String] = []) async throws -> ScanReport {
        try await DiskScanner(homeDirectory: tree.root).scan(
            enabledRuleIDs: ruleIDs,
            projectRoots: roots.map(tree.url)
        )
    }

    private func relativePaths(_ report: ScanReport, in tree: TemporaryTree) -> Set<String> {
        // The enumerator may report `/private/var/...` while the tree root is `/var/...`.
        Set(report.items.map { String($0.url!.resolvingSymlinksInPath().path.dropFirst(tree.root.path.count + 1)) })
    }

    @Test func projectArtifactsRequireMarkers() async throws {
        let tree = try TemporaryTree()
        try tree.file("Workspace/web/package.json")
        try tree.file("Workspace/web/node_modules/react/index.js")
        try tree.file("Workspace/web/node_modules/react/node_modules/nested/index.js")
        try tree.file("Workspace/notes/build/important.txt")
        try tree.file("Workspace/notes/target/important.txt")
        try tree.file("Workspace/crate/Cargo.toml")
        try tree.file("Workspace/crate/target/debug/bin")
        try tree.file("Workspace/android/app/build.gradle.kts")
        try tree.file("Workspace/android/app/build/outputs/app.apk")
        try tree.file("Workspace/py/.venv/pyvenv.cfg")
        try tree.file("Workspace/py/.venv/lib/site.py")
        try tree.file("Workspace/py/env/notes.txt")

        let ids = Set(RuleCatalog.all.filter { $0.group == .projectArtifacts }.map(\.id))
        let report = try await scan(tree, ruleIDs: ids, roots: ["Workspace"])

        #expect(relativePaths(report, in: tree) == [
            "Workspace/web/node_modules",
            "Workspace/crate/target",
            "Workspace/android/app/build",
            "Workspace/py/.venv",
        ])
        #expect(report.items.first { $0.url!.lastPathComponent == ".venv" }?.rule.risk == .caution)
    }

    @Test func hiddenDirectoriesAreNotDescended() async throws {
        let tree = try TemporaryTree()
        try tree.file("Workspace/repo/.git/modules/sub/package.json")
        try tree.file("Workspace/repo/.git/modules/sub/node_modules/x.js")

        let report = try await scan(tree, ruleIDs: ["project.nodeModules"], roots: ["Workspace"])
        #expect(report.items.isEmpty)
    }

    @Test func overlappingRootsAreDeduplicated() async throws {
        let tree = try TemporaryTree()
        try tree.file("Workspace/app/package.json")
        try tree.file("Workspace/app/node_modules/x.js")

        let report = try await scan(tree, ruleIDs: ["project.nodeModules"], roots: ["Workspace", "Workspace/app"])
        #expect(report.items.count == 1)
    }

    @Test func specificRulesClaimPathsFromGenericCacheRule() async throws {
        let tree = try TemporaryTree()
        try tree.file("Library/Caches/Homebrew/downloads/bottle.tar.gz")
        try tree.file("Library/Caches/com.example.app/cache.db")
        try tree.file("Library/Caches/JetBrains/IntelliJIdea2026.2/index.bin")

        let report = try await scan(tree, ruleIDs: ["system.userCaches", "pkg.homebrew", "editor.jetbrains"])
        let ruleByPath = Dictionary(uniqueKeysWithValues: report.items.map {
            (String($0.url!.path.dropFirst(tree.root.path.count + 1)), $0.rule.id)
        })
        #expect(ruleByPath == [
            "Library/Caches/Homebrew": "pkg.homebrew",
            "Library/Caches/com.example.app": "system.userCaches",
            "Library/Caches/JetBrains/IntelliJIdea2026.2": "editor.jetbrains",
        ])
    }

    @Test func disabledSpecificRuleDoesNotLeakIntoGenericRule() async throws {
        let tree = try TemporaryTree()
        try tree.file("Library/Caches/Homebrew/bottle.tar.gz")

        let report = try await scan(tree, ruleIDs: ["system.userCaches"])
        #expect(report.items.isEmpty)
    }

    @Test func emptyDirectoriesAreOmittedAndItemsSortedBySize() async throws {
        let tree = try TemporaryTree()
        try tree.directory("Library/Caches/empty")
        try tree.file("Library/Caches/small/a", bytes: 10)
        try tree.file("Library/Caches/large/a", bytes: 200_000)

        let report = try await scan(tree, ruleIDs: ["system.userCaches"])
        #expect(report.items.map(\.url?.lastPathComponent) == ["large", "small"])
    }
}
