import Foundation
import Testing
@testable import ApolloKitCore

@Suite struct SystemDataTests {
    private let runtimeList = """
    {
      "A": {"build": "22G86", "sizeBytes": 8000000000, "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-6"},
      "B": {"build": "23F77", "sizeBytes": 9000000000, "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5"}
    }
    """
    private let snapshots = """
    Snapshots for disk /:
    com.apple.TimeMachine.2026-10-24-101500.local
    com.apple.os.update-4C1F8A.local
    """

    private func scan(_ tree: TemporaryTree) async -> [SystemDataEntry.Kind: SystemDataEntry] {
        let runner = FakeToolRunner([
            ["simctl", "runtime", "list", "--json"]: ToolOutput(exitCode: 0, standardOutput: Data(runtimeList.utf8)),
            ["listlocalsnapshots", "/"]: ToolOutput(exitCode: 0, standardOutput: Data(snapshots.utf8)),
        ])
        let entries = await SystemDataScanner(
            runner: runner,
            homeDirectory: tree.url("home"),
            fileSystemRoot: tree.url("root"),
            userTemporaryDirectory: nil,
            hostBuild: "25F80"
        ).scan()
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.kind, $0) })
    }

    @Test func reportsSourcesThatExistAndSkipsTheRest() async throws {
        let tree = try TemporaryTree()
        try tree.file("home/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", bytes: 8192)
        try tree.file("root/private/var/db/diagnostics/Persist/a.tracev3", bytes: 4096)
        try tree.file("root/Library/Logs/DiagnosticReports/b.ips", bytes: 4096)

        let entries = await scan(tree)

        #expect(Set(entries.keys) == [.simulatorRuntimes, .dockerDisk, .systemLogs, .localSnapshots])
        #expect(entries[.simulatorRuntimes]?.bytes == 17_000_000_000)
        #expect(entries[.simulatorRuntimes]?.count == 2)
        #expect(entries[.simulatorRuntimes]?.remedy == .smartScan(.xcode))
        #expect(entries[.localSnapshots]?.count == 2)
        #expect(entries[.localSnapshots]?.bytes == nil)
        #expect(entries[.systemLogs]?.locations.count == 2)
        #expect((entries[.dockerDisk]?.bytes ?? 0) >= 8192)
    }

    @Test func flagsSimulatorCachesOfEarlierMacOSAndRemovedRuntimes() async throws {
        let tree = try TemporaryTree()
        let dyld = "root/Library/Developer/CoreSimulator/Caches/dyld"
        try tree.file("\(dyld)/25F80/com.apple.CoreSimulator.SimRuntime.iOS-18-6.22G86/cache", bytes: 4096)
        try tree.file("\(dyld)/24A335/com.apple.CoreSimulator.SimRuntime.iOS-18-6.22G86/cache", bytes: 4096)
        try tree.file("\(dyld)/25F80/com.apple.CoreSimulator.SimRuntime.iOS-17-5.21F79/cache", bytes: 4096)

        let caches = try #require(await scan(tree)[.simulatorCaches])

        #expect(caches.staleBytes > 0)
        #expect(caches.staleBytes < caches.bytes ?? 0)
        #expect(Set(caches.locations.map(\.lastPathComponent)) == [
            "com.apple.CoreSimulator.SimRuntime.iOS-18-6.22G86", "com.apple.CoreSimulator.SimRuntime.iOS-17-5.21F79",
        ])
        #expect(Set(caches.locations.map { $0.deletingLastPathComponent().lastPathComponent }) == ["24A335", "25F80"])
    }

    @Test func countsSnapshotLinesOnly() {
        #expect(SystemDataScanner.snapshotCount(in: snapshots) == 2)
        #expect(SystemDataScanner.snapshotCount(in: "Snapshots for disk /:\n") == 0)
    }
}
