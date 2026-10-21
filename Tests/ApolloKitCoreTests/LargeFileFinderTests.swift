import Foundation
import Testing
@testable import ApolloKitCore

@Suite struct LargeFileFinderTests {
    private static let threshold = 1_000_000
    private static let large = 1_200_000
    private let allLargeFileRules = Set(RuleCatalog.largeFiles.map(\.id))

    private func scan(_ tree: TemporaryTree, ruleIDs: Set<String>? = nil, projectRoots: [String] = []) async throws -> ScanReport {
        try await DiskScanner(
            homeDirectory: tree.root,
            tools: ToolEnvironment(runner: FakeToolRunner([:]), xcrun: nil, docker: nil),
            largeFileSearch: LargeFileSearch(minimumBytes: Int64(Self.threshold))
        ).scan(enabledRuleIDs: ruleIDs ?? allLargeFileRules, projectRoots: projectRoots.map(tree.url))
    }

    private func ruleByName(_ report: ScanReport) -> [String: String] {
        Dictionary(uniqueKeysWithValues: report.items.map { ($0.displayName, $0.rule.id) })
    }

    @Test func classifiesFilesAboveThresholdByExtension() async throws {
        let tree = try TemporaryTree()
        try tree.file("Downloads/Xcode_26.DMG", bytes: Self.large)
        try tree.file("Downloads/source.tar.gz", bytes: Self.large)
        try tree.file("Movies/Screen Recording.mov", bytes: Self.large)
        try tree.file("Documents/dump.sql", bytes: Self.large)
        try tree.file("Desktop/App.ipa", bytes: Self.large)
        try tree.file("Downloads/small.zip", bytes: 10_000)

        let report = try await scan(tree)
        #expect(ruleByName(report) == [
            "Xcode_26.DMG": "files.installers",
            "source.tar.gz": "files.archives",
            "Screen Recording.mov": "files.videos",
            "dump.sql": "files.other",
            "App.ipa": "files.appBuilds",
        ])
        #expect(report.items.allSatisfy { $0.rule.risk == .caution && $0.lastModified != nil })
    }

    @Test func neverEntersRepositoriesProjectsHiddenFoldersOrApps() async throws {
        let tree = try TemporaryTree()
        try tree.file("Documents/repo/.git/HEAD")
        try tree.file("Documents/repo/assets/model.bin", bytes: Self.large)
        try tree.file("Documents/.secret/archive.zip", bytes: Self.large)
        try tree.file("Documents/Tool.app/Contents/Resources/payload.bin", bytes: Self.large)
        try tree.file("Desktop/web/node_modules/blob.bin", bytes: Self.large)
        try tree.file("Documents/Clients/site/video.mp4", bytes: Self.large)
        try tree.file("Documents/Keep/report.pdf", bytes: Self.large)

        let report = try await scan(tree, projectRoots: ["Documents/Clients"])
        #expect(ruleByName(report) == ["report.pdf": "files.other"])
    }

    @Test func bundlesNamedByARuleAreMeasuredWholeAgainstTheThreshold() async throws {
        let tree = try TemporaryTree()
        try tree.file("Documents/Linux.utm/Data/disk.qcow2", bytes: Self.large)
        try tree.file("Documents/Tiny.sparsebundle/bands/0", bytes: 10_000)

        let report = try await scan(tree)
        let item = try #require(report.items.first)
        #expect(report.items.count == 1)
        #expect(item.displayName == "Linux.utm")
        #expect(item.rule.id == "files.virtualMachines")
        #expect(item.sizeInBytes >= Int64(Self.large))
    }

    @Test func disabledSpecificRuleDoesNotFallBackToOther() async throws {
        let tree = try TemporaryTree()
        try tree.file("Downloads/old.dmg", bytes: Self.large)
        try tree.file("Downloads/notes.key", bytes: Self.large)

        let report = try await scan(tree, ruleIDs: ["files.other"])
        #expect(ruleByName(report) == ["notes.key": "files.other"])
    }

    @Test func largeFilesCanBeCleanedFromDocumentFolders() throws {
        let tree = try TemporaryTree()
        let policy = SafetyPolicy(homeDirectory: tree.root)
        try policy.validate(tree.url("Downloads/old.dmg"))
        #expect(throws: SafetyPolicy.Violation.self) { try policy.validate(tree.url("Downloads")) }
    }
}
