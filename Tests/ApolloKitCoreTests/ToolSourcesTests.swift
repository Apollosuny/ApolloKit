import Foundation
import Testing
@testable import ApolloKitCore

/// Returns canned output keyed by the invocation's arguments and records every call.
final class FakeToolRunner: ToolRunner, @unchecked Sendable {
    private let lock = NSLock()
    private let responses: [[String]: ToolOutput]
    private var recorded: [ToolInvocation] = []

    init(_ responses: [[String]: ToolOutput]) {
        self.responses = responses
    }

    var invocations: [ToolInvocation] { lock.withLock { recorded } }

    func run(_ invocation: ToolInvocation, timeout: TimeInterval) async throws -> ToolOutput {
        lock.withLock { recorded.append(invocation) }
        return responses[invocation.arguments] ?? ToolOutput(exitCode: 127, standardError: Data("unexpected call".utf8))
    }
}

private let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
private let docker = URL(fileURLWithPath: "/usr/local/bin/docker")
private let dockerDFArguments = ["system", "df", "--format", "{{json .}}"]

private func output(_ text: String) -> ToolOutput {
    ToolOutput(exitCode: 0, standardOutput: Data(text.utf8))
}

private func rule(_ id: String) throws -> CleanupRule {
    try #require(RuleCatalog.rule(id: id))
}

@Suite struct DockerToolProviderTests {
    private let systemDF = """
    {"Active":"5","Reclaimable":"1.199GB (33%)","Size":"3.528GB","TotalCount":"8","Type":"Images"}
    {"Active":"0","Reclaimable":"0B","Size":"0B","TotalCount":"0","Type":"Containers"}
    {"Active":"3","Reclaimable":"48.75MB (14%)","Size":"347MB","TotalCount":"7","Type":"Local Volumes"}
    {"Active":"0","Reclaimable":"2.901GB","Size":"2.901GB","TotalCount":"73","Type":"Build Cache"}
    """

    @Test(arguments: [
        ("1.199GB (33%)", Int64(1_199_000_000)),
        ("48.75MB", 48_750_000),
        ("12kB", 12_000),
        ("0B", 0),
        ("1.5TB", 1_500_000_000_000),
    ])
    func parsesDockerSizes(text: String, expected: Int64) {
        #expect(DockerToolProvider.parseSize(text) == expected)
    }

    @Test func rejectsUnparseableSizes() {
        #expect(DockerToolProvider.parseSize("N/A") == nil)
        #expect(DockerToolProvider.parseSize("") == nil)
    }

    @Test func reportsReclaimableSpaceOnlyForRequestedResources() async throws {
        let runner = FakeToolRunner([dockerDFArguments: output(systemDF)])
        let result = await DockerToolProvider(docker: docker, runner: runner).items(for: [
            (.buildCache, try rule("docker.buildCache")),
            (.unusedImages, try rule("docker.images")),
            (.stoppedContainers, try rule("docker.containers")),
        ])

        let byID = Dictionary(uniqueKeysWithValues: result.items.map { ($0.id, $0) })
        #expect(Set(byID.keys) == ["docker.buildCache", "docker.unusedImages"])
        #expect(byID["docker.buildCache"]?.sizeInBytes == 2_901_000_000)
        #expect(byID["docker.unusedImages"]?.action == .runTool(ToolInvocation(
            executable: docker, arguments: ["image", "prune", "--all", "--force"]
        )))
        #expect(byID["docker.buildCache"]?.isAlwaysPermanent == true)
        #expect(result.issues.isEmpty)
    }

    @Test func unreachableDaemonBecomesAnIssue() async throws {
        let failure = ToolOutput(exitCode: 1, standardError: Data("Cannot connect to the Docker daemon".utf8))
        let result = await DockerToolProvider(docker: docker, runner: FakeToolRunner([dockerDFArguments: failure]))
            .items(for: [(.buildCache, try rule("docker.buildCache"))])

        #expect(result.items.isEmpty)
        #expect(result.issues.count == 1)
        #expect(result.issues.first?.message.contains("Cannot connect") == true)
    }
}

@Suite struct SimulatorToolProviderTests {
    @Test func listsOnlyDeletableRuntimes() async throws {
        let json = """
        {
          "8441E0D1": {"identifier": "8441E0D1", "version": "18.6", "build": "22G86", "deletable": true,
                       "sizeBytes": 8838255185, "lastUsedAt": "2026-09-30T02:07:55Z",
                       "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-6"},
          "BUNDLED1": {"identifier": "BUNDLED1", "version": "26.5", "deletable": false, "sizeBytes": 9000000000,
                       "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5"}
        }
        """
        let runner = FakeToolRunner([["simctl", "runtime", "list", "--json"]: output(json)])
        let result = await SimulatorToolProvider(xcrun: xcrun, runner: runner).runtimes(rule: try rule("xcode.simulatorRuntimes"))

        let item = try #require(result.items.first)
        #expect(result.items.count == 1)
        #expect(item.displayName == "iOS 18.6 (22G86)")
        #expect(item.sizeInBytes == 8_838_255_185)
        #expect(item.lastModified == (try Date("2026-09-30T02:07:55Z", strategy: .iso8601)))
        #expect(item.url == nil)
        #expect(item.action == .runTool(ToolInvocation(executable: xcrun, arguments: ["simctl", "runtime", "delete", "8441E0D1"])))
    }

    @Test func measuresUnavailableDeviceFolders() async throws {
        let tree = try TemporaryTree()
        try tree.file("Devices/ABC-123/data/Containers/app.bin", bytes: 40_000)
        try tree.directory("Devices/EMPTY-1/data")
        let json = """
        {"devices": {
          "com.apple.CoreSimulator.SimRuntime.iOS-17-0": [
            {"udid": "ABC-123", "name": "iPhone 15", "dataPath": "\(tree.url("Devices/ABC-123/data").path)"},
            {"udid": "EMPTY-1", "name": "iPad", "dataPath": "\(tree.url("Devices/EMPTY-1/data").path)"}
          ],
          "com.apple.CoreSimulator.SimRuntime.watchOS-10-0": []
        }}
        """
        let runner = FakeToolRunner([["simctl", "list", "devices", "unavailable", "--json"]: output(json)])
        let result = await SimulatorToolProvider(xcrun: xcrun, runner: runner)
            .unavailableDevices(rule: try rule("xcode.unavailableSimulators"))

        let item = try #require(result.items.first)
        #expect(result.items.count == 1)
        #expect(item.displayName == "iPhone 15 (iOS 17.0)")
        #expect(item.url?.lastPathComponent == "ABC-123")
        #expect(item.sizeInBytes >= 40_000)
        #expect(item.action == .runTool(ToolInvocation(executable: xcrun, arguments: ["simctl", "delete", "ABC-123"])))
    }

    @Test func missingSimctlIsNotReported() async throws {
        let failure = ToolOutput(exitCode: 72, standardError: Data("xcrun: error: unable to find utility \"simctl\"".utf8))
        let runner = FakeToolRunner([["simctl", "runtime", "list", "--json"]: failure])
        let result = await SimulatorToolProvider(xcrun: xcrun, runner: runner).runtimes(rule: try rule("xcode.simulatorRuntimes"))

        #expect(result.items.isEmpty)
        #expect(result.issues.isEmpty)
    }
}

@Suite struct ToolCleanupTests {
    private func toolItem(_ arguments: [String]) throws -> CleanupItem {
        CleanupItem(
            id: "docker.buildCache", rule: try rule("docker.buildCache"), displayName: "Build cache", url: nil,
            action: .runTool(ToolInvocation(executable: docker, arguments: arguments)),
            sizeInBytes: 1_000, lastModified: nil
        )
    }

    @Test func runsToolAndReportsSuccess() async throws {
        let arguments = ["builder", "prune", "--all", "--force"]
        let runner = FakeToolRunner([arguments: output("Total reclaimed space: 1kB")])
        let tree = try TemporaryTree()

        let outcome = await Cleaner(policy: SafetyPolicy(homeDirectory: tree.root), runner: runner)
            .clean([try toolItem(arguments)], mode: .moveToTrash)

        #expect(outcome.removed.count == 1)
        #expect(outcome.reclaimedBytes == 1_000)
        #expect(runner.invocations.map(\.arguments) == [arguments])
    }

    @Test func nonZeroExitIsAFailure() async throws {
        let arguments = ["builder", "prune", "--all", "--force"]
        let runner = FakeToolRunner([arguments: ToolOutput(exitCode: 1, standardError: Data("daemon down".utf8))])
        let tree = try TemporaryTree()

        let outcome = await Cleaner(policy: SafetyPolicy(homeDirectory: tree.root), runner: runner)
            .clean([try toolItem(arguments)], mode: .deletePermanently)

        #expect(outcome.removed.isEmpty)
        #expect(outcome.failures.first?.reason.contains("daemon down") == true)
    }

    @Test func scannerMergesToolItemsWithFileItems() async throws {
        let tree = try TemporaryTree()
        try tree.file("Library/Caches/com.example/a", bytes: 10)
        let runner = FakeToolRunner([
            dockerDFArguments: output(#"{"Reclaimable":"2GB","Type":"Build Cache"}"#),
        ])
        let scanner = DiskScanner(
            homeDirectory: tree.root,
            tools: ToolEnvironment(runner: runner, xcrun: nil, docker: docker)
        )

        let report = try await scanner.scan(enabledRuleIDs: ["system.userCaches", "docker.buildCache"], projectRoots: [])
        #expect(report.items.map(\.id).first == "docker.buildCache")
        #expect(report.items.count == 2)
    }

    @Test func dockerVolumesAreOptIn() throws {
        #expect(try rule("docker.volumes").enabledByDefault == false)
    }
}

@Suite struct ScanProgressTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [ScanProgress] = []
        func record(_ event: ScanProgress) { lock.withLock { events.append(event) } }
        var discoveredBytes: [RuleGroup: Int64] {
            lock.withLock {
                events.reduce(into: [:]) { totals, event in
                    if case .discovered(let group, let bytes) = event { totals[group, default: 0] += bytes }
                }
            }
        }
    }

    @Test func discoveredEventsAddUpToTheReport() async throws {
        let tree = try TemporaryTree()
        try tree.file("Library/Caches/com.example/a", bytes: 50_000)
        try tree.file("Workspace/web/package.json")
        try tree.file("Workspace/web/node_modules/x.js", bytes: 20_000)
        let runner = FakeToolRunner([
            ["system", "df", "--format", "{{json .}}"]: ToolOutput(exitCode: 0, standardOutput: Data(#"{"Reclaimable":"1GB","Type":"Build Cache"}"#.utf8)),
        ])
        let recorder = Recorder()

        let report = try await DiskScanner(
            homeDirectory: tree.root,
            tools: ToolEnvironment(runner: runner, xcrun: nil, docker: URL(fileURLWithPath: "/usr/local/bin/docker"))
        ).scan(
            enabledRuleIDs: ["system.userCaches", "project.nodeModules", "docker.buildCache"],
            projectRoots: [tree.url("Workspace")],
            progress: { recorder.record($0) }
        )

        let expected = Dictionary(grouping: report.items, by: \.rule.group).mapValues { $0.reduce(0) { $0 + $1.sizeInBytes } }
        #expect(recorder.discoveredBytes == expected)
        #expect(Set(expected.keys) == [.system, .projectArtifacts, .docker])
    }
}
