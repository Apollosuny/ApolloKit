import Foundation
import Testing
@testable import ApolloKitCore

@Suite struct SafetyPolicyTests {
    @Test func acceptsItemsInsideHome() throws {
        let tree = try TemporaryTree()
        let policy = SafetyPolicy(homeDirectory: tree.root)
        try policy.validate(tree.url("Library/Caches/com.example"))
        try policy.validate(tree.url("Workspace/app/node_modules"))
    }

    @Test func rejectsProtectedLocationsAndTheirAncestors() throws {
        let tree = try TemporaryTree()
        let policy = SafetyPolicy(homeDirectory: tree.root)
        for path in ["Library", "Library/Caches", "Documents", ".ssh", ""] {
            #expect(throws: SafetyPolicy.Violation.self) { try policy.validate(tree.url(path)) }
        }
    }

    @Test func rejectsPathsOutsideAllowedRoots() throws {
        let tree = try TemporaryTree()
        let policy = SafetyPolicy(homeDirectory: tree.url("home"))
        #expect(throws: SafetyPolicy.Violation.self) { try policy.validate(tree.url("other/node_modules")) }
        #expect(throws: SafetyPolicy.Violation.self) { try policy.validate(tree.url("home/../other/x")) }
    }

    @Test func rejectsSymlinkedParentEscapingHome() throws {
        let tree = try TemporaryTree()
        try tree.directory("home")
        try tree.file("outside/secret/data")
        try FileManager.default.createSymbolicLink(at: tree.url("home/link"), withDestinationURL: tree.url("outside"))

        let policy = SafetyPolicy(homeDirectory: tree.url("home"))
        #expect(throws: SafetyPolicy.Violation.self) { try policy.validate(tree.url("home/link/secret")) }
    }

    @Test func additionalRootsAreAllowedButNotDeletableThemselves() throws {
        let tree = try TemporaryTree()
        let policy = SafetyPolicy(homeDirectory: tree.url("home"), additionalAllowedRoots: [tree.url("Volumes/Dev")])
        try policy.validate(tree.url("Volumes/Dev/app/node_modules"))
        #expect(throws: SafetyPolicy.Violation.self) { try policy.validate(tree.url("Volumes/Dev")) }
    }
}

@Suite struct CleanerTests {
    private func item(_ url: URL, ruleID: String) throws -> CleanupItem {
        CleanupItem(url: url, rule: try #require(RuleCatalog.rule(id: ruleID)), sizeInBytes: 100, lastModified: nil)
    }

    @Test func permanentlyDeletesReadOnlyDirectories() async throws {
        let tree = try TemporaryTree()
        try tree.file("go/pkg/mod/example.com/lib@v1.0.0/lib.go")
        let fileManager = FileManager.default
        for path in ["go/pkg/mod/example.com/lib@v1.0.0", "go/pkg/mod/example.com"] {
            try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: tree.url(path).path)
        }

        let target = tree.url("go/pkg/mod")
        let outcome = await Cleaner(policy: SafetyPolicy(homeDirectory: tree.root))
            .clean([try item(target, ruleID: "pkg.goModules")], mode: .deletePermanently)

        #expect(outcome.failures.isEmpty)
        #expect(outcome.removed.count == 1)
        #expect(!fileManager.fileExists(atPath: target.path))
    }

    @Test func missingItemsAreReportedSeparately() async throws {
        let tree = try TemporaryTree()
        let outcome = await Cleaner(policy: SafetyPolicy(homeDirectory: tree.root))
            .clean([try item(tree.url("Library/Caches/gone"), ruleID: "system.userCaches")], mode: .deletePermanently)

        #expect(outcome.missing.count == 1)
        #expect(outcome.removed.isEmpty)
        #expect(outcome.reclaimedBytes == 0)
    }

    @Test func policyViolationIsAFailureAndNothingIsRemoved() async throws {
        let tree = try TemporaryTree()
        let protected = try tree.directory("Library/Caches")
        let outcome = await Cleaner(policy: SafetyPolicy(homeDirectory: tree.root))
            .clean([try item(protected, ruleID: "system.userCaches")], mode: .deletePermanently)

        #expect(outcome.failures.count == 1)
        #expect(FileManager.default.fileExists(atPath: protected.path))
    }

    @Test func symlinkItemRemovesOnlyTheLink() async throws {
        let tree = try TemporaryTree()
        let realFile = try tree.file("Workspace/keep/data.bin")
        let link = tree.url("Library/Caches/link")
        try tree.directory("Library/Caches")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realFile.deletingLastPathComponent())

        let outcome = await Cleaner(policy: SafetyPolicy(homeDirectory: tree.root))
            .clean([try item(link, ruleID: "system.userCaches")], mode: .deletePermanently)

        #expect(outcome.removed.count == 1)
        #expect(FileManager.default.fileExists(atPath: realFile.path))
    }
}

@Suite struct RuleCatalogTests {
    @Test func ruleIdentifiersAreUnique() {
        let ids = RuleCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func genericArtifactNamesRequireMarkers() {
        let generic: Set<String> = [
            "build", "target", "deps", "_build", "venv", "env", "dist", "vendor", ".gradle", ".build", "Pods",
            "bin", "obj", ".cache", ".output", ".tox", ".expo",
        ]
        let patterns = RuleCatalog.all.flatMap(\.locators).compactMap(\.artifactPattern)
        for pattern in patterns where generic.contains(pattern.directoryName) {
            #expect(pattern.hasMarkers, "\(pattern.directoryName) must be confirmed by marker files")
        }
    }

    @Test func directorySizerCountsNestedFilesWithoutFollowingSymlinks() throws {
        let tree = try TemporaryTree()
        try tree.file("measured/a/b/c.bin", bytes: 50_000)
        let big = try tree.file("elsewhere/huge.bin", bytes: 2_000_000)
        try FileManager.default.createSymbolicLink(at: tree.url("measured/link"), withDestinationURL: big)

        let measurement = DirectorySizer.measure(tree.url("measured"))
        #expect(measurement.allocatedBytes >= 50_000)
        #expect(measurement.allocatedBytes < 2_000_000)
        #expect(measurement.unreadableEntryCount == 0)
    }
}
