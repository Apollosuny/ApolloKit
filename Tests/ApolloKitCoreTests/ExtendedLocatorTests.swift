import Foundation
import Testing
@testable import ApolloKitCore

@Suite struct ExtendedLocatorTests {
    private func scan(
        _ tree: TemporaryTree,
        ruleIDs: Set<String>,
        roots: [String] = [],
        applications: [String] = ["Applications"]
    ) async throws -> ScanReport {
        try await DiskScanner(
            homeDirectory: tree.root,
            tools: ToolEnvironment(runner: FakeToolRunner([:]), xcrun: nil, docker: nil),
            applicationDirectories: applications.map(tree.url)
        ).scan(enabledRuleIDs: ruleIDs, projectRoots: roots.map(tree.url))
    }

    private func names(_ report: ScanReport) -> Set<String> {
        Set(report.items.map(\.displayName))
    }

    @Test func eachChildFindsCachesPerBrowserProfile() async throws {
        let tree = try TemporaryTree()
        try tree.file("Library/Application Support/Google/Chrome/Default/Code Cache/js/a")
        try tree.file("Library/Application Support/Google/Chrome/Profile 3/GPUCache/b")
        try tree.file("Library/Application Support/Google/Chrome/Default/History")
        try tree.file("Library/Application Support/Google/Chrome/Default/Service Worker/CacheStorage/c")

        let report = try await scan(tree, ruleIDs: ["apps.browserCaches"])
        #expect(names(report) == ["Chrome › Default › Code Cache", "Chrome › Profile 3 › GPUCache"])
    }

    @Test func rustupDefaultToolchainIsNeverListed() async throws {
        let tree = try TemporaryTree()
        try tree.file(".rustup/settings.toml", bytes: 0)
        try #"default_toolchain = "1.79.0-aarch64-apple-darwin""#.write(
            to: tree.url(".rustup/settings.toml"), atomically: true, encoding: .utf8
        )
        for toolchain in ["1.79.0-aarch64-apple-darwin", "1.75.0-aarch64-apple-darwin", "nightly-aarch64-apple-darwin"] {
            try tree.file(".rustup/toolchains/\(toolchain)/bin/rustc")
        }

        let report = try await scan(tree, ruleIDs: ["toolchain.rust"])
        #expect(names(report) == ["rustup 1.75.0-aarch64-apple-darwin", "rustup nightly-aarch64-apple-darwin"])
    }

    @Test(arguments: [
        ("22", "v22.23.2"),
        ("v20.18.3", "v20.18.3"),
        ("node", "v23.9.0"),
        ("lts/*", "v23.9.0"),
    ])
    func nvmDefaultVersionIsProtected(alias: String, protected: String) {
        let tree = try! TemporaryTree()
        try! tree.file(".nvm/alias/default", bytes: 0)
        try! alias.write(to: tree.url(".nvm/alias/default"), atomically: true, encoding: .utf8)

        let installed = ["v18.20.4", "v20.18.3", "v22.1.0", "v22.23.2", "v23.9.0"]
        #expect(ToolchainManager.nvm.protectedVersions(installed: installed, homeDirectory: tree.root) == [protected])
    }

    @Test func nvmWithoutAliasKeepsNewestVersion() throws {
        let tree = try TemporaryTree()
        let protected = ToolchainManager.nvm.protectedVersions(installed: ["v9.0.0", "v10.1.0"], homeDirectory: tree.root)
        #expect(protected == ["v10.1.0"])
    }

    @Test func pyenvGlobalVersionsAreProtected() throws {
        let tree = try TemporaryTree()
        try tree.file(".pyenv/version", bytes: 0)
        try "3.13.2\nsystem\n".write(to: tree.url(".pyenv/version"), atomically: true, encoding: .utf8)
        let protected = ToolchainManager.pyenv.protectedVersions(installed: ["3.12.1", "3.13.2"], homeDirectory: tree.root)
        #expect(protected == ["3.13.2"])
    }

    @Test func leftoversAreReportedOnlyWhenTheAppIsMissing() async throws {
        let tree = try TemporaryTree()
        try tree.file("Library/Group Containers/HUAQ24HBR6.dev.orbstack/data.img", bytes: 1_000)

        let missing = try await scan(tree, ruleIDs: ["apps.leftovers"])
        #expect(names(missing) == ["OrbStack (not installed) › HUAQ24HBR6.dev.orbstack"])

        try tree.directory("Applications/OrbStack.app")
        let installed = try await scan(tree, ruleIDs: ["apps.leftovers"])
        #expect(installed.items.isEmpty)
    }

    @Test func dotnetArtifactsMatchProjectFileExtensions() async throws {
        let tree = try TemporaryTree()
        try tree.file("Workspace/api/Api.csproj")
        try tree.file("Workspace/api/bin/Debug/api.dll")
        try tree.file("Workspace/api/obj/project.assets.json")
        try tree.file("Workspace/scripts/bin/deploy.sh")

        let report = try await scan(tree, ruleIDs: ["project.dotnet"], roots: ["Workspace"])
        #expect(names(report) == ["api/bin", "api/obj"])
    }

    @Test func genericCLICacheRuleLeavesSpecificCachesToTheirRules() async throws {
        let tree = try TemporaryTree()
        try tree.file(".cache/prisma/engine")
        try tree.file(".cache/huggingface/hub/model.bin")
        try tree.file(".cache/uv/wheels/a.whl")

        let report = try await scan(tree, ruleIDs: ["pkg.xdgCache", "toolchain.aiModels"])
        let ruleByName = Dictionary(uniqueKeysWithValues: report.items.map { ($0.displayName, $0.rule.id) })
        #expect(ruleByName == ["prisma": "pkg.xdgCache", ".cache › huggingface": "toolchain.aiModels"])
    }

    @Test func fixedDirectoriesShowTheirOwningApp() {
        #expect(DiskScanner.displayName(forHomeRelativePath: "Library/Application Support/Notion/Partitions/notion/Cache")
            == "Notion › Partitions › notion › Cache")
        #expect(DiskScanner.displayName(forHomeRelativePath: ".gradle/daemon") == ".gradle › daemon")
    }

    @Test func simulatorClonesUseTheirDeviceName() async throws {
        let tree = try TemporaryTree()
        let clone = try tree.directory("Library/Developer/XCTestDevices/11CDB72B-1650-4B84-B2B6-AE885DD9E4B7")
        try tree.file("Library/Developer/XCTestDevices/11CDB72B-1650-4B84-B2B6-AE885DD9E4B7/data/a.bin")
        let plist = try PropertyListSerialization.data(fromPropertyList: ["name": "Clone 1 of iPhone 16"], format: .xml, options: 0)
        try plist.write(to: clone.appendingPathComponent("device.plist"))

        let report = try await scan(tree, ruleIDs: ["xcode.testDevices"])
        #expect(names(report) == ["Clone 1 of iPhone 16 · 11CDB72B"])
    }

    @Test func labeledChildrenArePrefixed() async throws {
        let tree = try TemporaryTree()
        try tree.file("Library/Android/sdk/ndk/27.1.12297006/source.properties")

        let report = try await scan(tree, ruleIDs: ["toolchain.androidSDK"])
        #expect(names(report) == ["NDK 27.1.12297006"])
    }

    @Test func newProtectedParentsCannotBeDeleted() throws {
        let tree = try TemporaryTree()
        let policy = SafetyPolicy(homeDirectory: tree.root)
        for path in [".rustup/toolchains", "Library/Group Containers", ".cache", "Library/Application Support/MobileSync"] {
            #expect(throws: SafetyPolicy.Violation.self) { try policy.validate(tree.url(path)) }
        }
        try policy.validate(tree.url(".rustup/toolchains/1.75.0-aarch64-apple-darwin"))
    }
}

@Suite struct SimulatorDeviceDataTests {
    private let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")

    @Test func erasesOnlyShutDownDevices() async throws {
        let tree = try TemporaryTree()
        try tree.file("Devices/IDLE/data/app.bin", bytes: 30_000)
        try tree.file("Devices/BOOTED/data/app.bin", bytes: 30_000)
        let json = """
        {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
          {"udid": "IDLE", "name": "iPhone 16", "state": "Shutdown", "lastBootedAt": "2026-09-30T02:07:55Z",
           "dataPath": "\(tree.url("Devices/IDLE/data").path)"},
          {"udid": "BOOTED", "name": "iPhone Air", "state": "Booted",
           "dataPath": "\(tree.url("Devices/BOOTED/data").path)"}
        ]}}
        """
        let runner = FakeToolRunner([
            ["simctl", "list", "devices", "available", "--json"]: ToolOutput(exitCode: 0, standardOutput: Data(json.utf8)),
        ])
        let rule = try #require(RuleCatalog.rule(id: "xcode.simulatorDeviceData"))
        let result = await SimulatorToolProvider(xcrun: xcrun, runner: runner).deviceData(rule: rule)

        let item = try #require(result.items.first)
        #expect(result.items.count == 1)
        #expect(item.displayName == "iPhone 16 (iOS 26.5)")
        #expect(item.lastModified == (try Date("2026-09-30T02:07:55Z", strategy: .iso8601)))
        #expect(item.action == .runTool(ToolInvocation(executable: xcrun, arguments: ["simctl", "erase", "IDLE"])))
    }

    @Test func flagsRuntimeUsedByCurrentXcode() async throws {
        let json = """
        {
          "A": {"identifier": "A", "version": "26.5", "build": "23F77", "deletable": true, "sizeBytes": 100,
                "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5"},
          "B": {"identifier": "B", "version": "26.3.1", "build": "23D8133", "deletable": true, "sizeBytes": 100,
                "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-3"}
        }
        """
        let runner = FakeToolRunner([
            ["simctl", "runtime", "list", "--json"]: ToolOutput(exitCode: 0, standardOutput: Data(json.utf8)),
            ["--sdk", "iphonesimulator", "--show-sdk-version"]: ToolOutput(exitCode: 0, standardOutput: Data("26.5\n".utf8)),
        ])
        let rule = try #require(RuleCatalog.rule(id: "xcode.simulatorRuntimes"))
        let result = await SimulatorToolProvider(xcrun: xcrun, runner: runner).runtimes(rule: rule)

        #expect(Set(result.items.map(\.displayName)) == [
            "iOS 26.5 (23F77) — used by current Xcode",
            "iOS 26.3.1 (23D8133)",
        ])
    }
}
