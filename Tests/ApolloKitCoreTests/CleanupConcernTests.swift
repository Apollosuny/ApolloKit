import Foundation
import Testing
@testable import ApolloKitCore

private func lsofOutput(_ text: String) -> ToolOutput {
    ToolOutput(exitCode: 0, standardOutput: Data(text.utf8))
}

private func monitor(_ listing: String, currentProcessID: pid_t = 999) -> (FileUsageMonitor, FakeToolRunner) {
    let probe = FileUsageMonitor(runner: FakeToolRunner([:]), userID: 501, currentProcessID: currentProcessID)
    let runner = FakeToolRunner([probe.arguments: lsofOutput(listing)])
    return (FileUsageMonitor(runner: runner, userID: 501, currentProcessID: currentProcessID), runner)
}

@Suite struct FileUsageTests {
    @Test func matchesOpenFilesBelowAnItemButNotSiblingsWithTheSamePrefix() async throws {
        let (usage, _) = monitor("""
        p100
        cuv
        fcwd
        n/Users/me/.cache/uv
        f12
        n/Users/me/.cache/uv/archive-v0/abc/lib.so
        p200
        cnode
        ftxt
        n/Users/me/.nvm/versions/node/v20.1.0/bin/node
        f30
        n127.0.0.1:3000->127.0.0.1:52000
        p999
        cApolloKit
        f5
        n/Users/me/.cache/prisma/engine
        """)

        let snapshot = try await usage.snapshot()
        let found = snapshot.processes(using: [
            URL(fileURLWithPath: "/Users/me/.cache/uv"),
            URL(fileURLWithPath: "/Users/me/.cache/u"),
            URL(fileURLWithPath: "/Users/me/.nvm/versions/node/v20.1.0"),
            URL(fileURLWithPath: "/Users/me/.cache/prisma"),
        ])

        #expect(found == [
            "/Users/me/.cache/uv": ["uv"],
            "/Users/me/.nvm/versions/node/v20.1.0": ["node"],
        ])
    }

    @Test func cleanerSkipsItemsInUseAndRemovesTheRest() async throws {
        let tree = try TemporaryTree()
        let busy = try tree.directory(".cache/uv")
        try tree.file(".cache/uv/archive/lib.so")
        let idle = try tree.directory(".cache/prisma")
        try tree.file(".cache/prisma/engine")
        let (usage, runner) = monitor("p100\ncuv\nf12\nn\(busy.path)/archive/lib.so\n")
        let rule = try #require(RuleCatalog.rule(id: "pkg.xdgCache"))

        let outcome = await Cleaner(policy: SafetyPolicy(homeDirectory: tree.root), fileUsage: usage).clean([
            CleanupItem(url: busy, rule: rule, sizeInBytes: 1, lastModified: nil),
            CleanupItem(url: idle, rule: rule, sizeInBytes: 1, lastModified: nil),
        ], mode: .deletePermanently)

        #expect(outcome.removed.map(\.url) == [idle])
        #expect(outcome.failures.map(\.reason) == ["In use by uv. Quit it and try again."])
        #expect(FileManager.default.fileExists(atPath: busy.path))
        #expect(!FileManager.default.fileExists(atPath: idle.path))
        #expect(runner.invocations.count == 1)
    }

    @Test func cleanerProceedsWhenLsofFails() async throws {
        let tree = try TemporaryTree()
        let cache = try tree.directory(".cache/tool")
        let failing = FileUsageMonitor(runner: FakeToolRunner([:]), userID: 501, currentProcessID: 999)
        let rule = try #require(RuleCatalog.rule(id: "pkg.xdgCache"))

        let outcome = await Cleaner(policy: SafetyPolicy(homeDirectory: tree.root), fileUsage: failing)
            .clean([CleanupItem(url: cache, rule: rule, sizeInBytes: 1, lastModified: nil)], mode: .deletePermanently)

        #expect(outcome.removed.count == 1)
    }
}

@Suite struct ProgramDetectionTests {
    private func write(_ bytes: [UInt8], to relativePath: String, in tree: TemporaryTree, executable: Bool) throws {
        let url = try tree.file(relativePath, bytes: 0)
        try Data(bytes + Array(repeating: 0, count: 60)).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
    }

    @Test func detectsExecutableMachOAndScriptsOnly() throws {
        let tree = try TemporaryTree()
        try write([0xCF, 0xFA, 0xED, 0xFE], to: "binary/bin/tool", in: tree, executable: true)
        try write(Array("#!/bin/sh".utf8), to: "script/run", in: tree, executable: true)
        try write([0x41, 0x41, 0x41, 0x41], to: "data/blob", in: tree, executable: true)
        try write(Array("#!/bin/sh".utf8), to: "plain/run", in: tree, executable: false)

        #expect(DirectorySizer.measure(tree.url("binary"), detectsPrograms: true).containsPrograms)
        #expect(DirectorySizer.measure(tree.url("script"), detectsPrograms: true).containsPrograms)
        #expect(!DirectorySizer.measure(tree.url("data"), detectsPrograms: true).containsPrograms)
        #expect(!DirectorySizer.measure(tree.url("plain"), detectsPrograms: true).containsPrograms)
        #expect(!DirectorySizer.measure(tree.url("binary")).containsPrograms)
    }

    @Test func genericCacheFoldersHoldingProgramsBecomeCaution() async throws {
        let tree = try TemporaryTree()
        try write([0xCF, 0xFA, 0xED, 0xFE], to: ".cache/opencode/bin/opencode", in: tree, executable: true)
        try tree.file(".cache/gh/abc")

        let report = try await DiskScanner(
            homeDirectory: tree.root,
            tools: ToolEnvironment(runner: FakeToolRunner([:]), xcrun: nil, docker: nil)
        ).scan(enabledRuleIDs: ["pkg.xdgCache"], projectRoots: [])

        let byName = Dictionary(uniqueKeysWithValues: report.items.map { ($0.displayName, $0) })
        #expect(byName["opencode"]?.concerns == [.containsPrograms])
        #expect(byName["opencode"]?.risk == .caution)
        #expect(byName["gh"]?.concerns == [])
        #expect(byName["gh"]?.risk == .safe)
    }
}

@Suite struct NodeVersionTests {
    @Test func reportsGlobalToolsInstalledIntoAVersion() async throws {
        let tree = try TemporaryTree()
        try tree.file(".nvm/alias/default", bytes: 0)
        try "22".write(to: tree.url(".nvm/alias/default"), atomically: true, encoding: .utf8)
        try tree.file(".nvm/versions/node/v22.1.0/bin/node")
        try tree.file(".nvm/versions/node/v20.1.0/lib/node_modules/npm/package.json")
        try tree.file(".nvm/versions/node/v20.1.0/lib/node_modules/corepack/package.json")
        try tree.file(".nvm/versions/node/v20.1.0/lib/node_modules/@haravan/cli/package.json")
        try tree.file(".nvm/versions/node/v20.1.0/lib/node_modules/vercel/package.json")
        try tree.file(".nvm/versions/node/v18.1.0/lib/node_modules/npm/package.json")

        let report = try await DiskScanner(
            homeDirectory: tree.root,
            tools: ToolEnvironment(runner: FakeToolRunner([:]), xcrun: nil, docker: nil)
        ).scan(enabledRuleIDs: ["toolchain.node"], projectRoots: [])

        let byName = Dictionary(uniqueKeysWithValues: report.items.map { ($0.displayName, $0) })
        #expect(byName.keys.sorted() == ["nvm v18.1.0", "nvm v20.1.0"])
        #expect(byName["nvm v20.1.0"]?.concerns == [.globalTools(["@haravan/cli", "vercel"])])
        #expect(byName["nvm v18.1.0"]?.concerns == [])
    }

    @Test func followsLtsAliasChainsToTheDefaultVersion() throws {
        let tree = try TemporaryTree()
        for (path, value) in [("default", "lts/*"), ("lts/*", "lts/jod"), ("lts/jod", "v22.23.4")] {
            try tree.file(".nvm/alias/\(path)", bytes: 0)
            try value.write(to: tree.url(".nvm/alias/\(path)"), atomically: true, encoding: .utf8)
        }

        let protected = ToolchainManager.nvm.protectedVersions(
            installed: ["v20.18.3", "v22.23.4", "v24.1.0"],
            homeDirectory: tree.root
        )
        #expect(protected == ["v22.23.4"])
    }
}

@Suite struct CleanupRecordLocationTests {
    @Test func keepsLocationsLargestFirstAndReadsOlderRecordsWithout() throws {
        let rule = try #require(RuleCatalog.rule(id: "system.userCaches"))
        let record = CleanupRecord(source: .smartScan, removed: [
            CleanupItem(url: URL(fileURLWithPath: "/Users/me/Library/Caches/small"), rule: rule, sizeInBytes: 1, lastModified: nil),
            CleanupItem(url: URL(fileURLWithPath: "/Users/me/Library/Caches/large"), rule: rule, sizeInBytes: 9, lastModified: nil),
        ], movedToTrash: false)
        #expect(record.locations == ["/Users/me/Library/Caches/large", "/Users/me/Library/Caches/small"])

        let tree = try TemporaryTree()
        let store = CleanupHistoryStore(fileURL: tree.url("history.json"))
        try store.save(CleanupHistory(records: [record]))
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        var records = try #require(json["records"] as? [[String: Any]])
        records[0].removeValue(forKey: "locations")
        json["records"] = records
        try JSONSerialization.data(withJSONObject: json).write(to: store.fileURL)

        let loaded = store.load()
        #expect(loaded.records.count == 1)
        #expect(loaded.records[0].locations == nil)
    }
}
