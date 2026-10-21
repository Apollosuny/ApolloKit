import Foundation
import Testing
@testable import ApolloKitCore

@Suite struct CleanupHistoryTests {
    private let day: TimeInterval = 24 * 60 * 60
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ ruleID: String, _ bytes: Int64) throws -> CleanupItem {
        let rule = try #require(RuleCatalog.rule(id: ruleID))
        return CleanupItem(url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)"), rule: rule, sizeInBytes: bytes, lastModified: nil)
    }

    @Test func recordsBytesPerGroup() throws {
        let record = CleanupRecord(date: now, source: .smartScan, removed: [
            try item("system.userCaches", 100), try item("xcode.derivedData", 300), try item("xcode.previews", 50),
        ], movedToTrash: true)

        #expect(record.itemCount == 3)
        #expect(record.reclaimedBytes == 450)
        #expect(record.bytesByGroup == ["system": 100, "xcode": 350])
    }

    @Test func totalsAndRecentWindow() throws {
        var history = CleanupHistory()
        history.append(CleanupRecord(date: now.addingTimeInterval(-40 * day), source: .smartScan, removed: [try item("system.userCaches", 1_000)], movedToTrash: false))
        history.append(CleanupRecord(date: now.addingTimeInterval(-2 * day), source: .uninstaller, title: "Zoom", removed: [try item("system.userCaches", 500)], movedToTrash: true))
        history.append(CleanupRecord(date: now, source: .smartScan, removed: [], movedToTrash: true))

        #expect(history.records.count == 2)
        #expect(history.totalReclaimedBytes == 1_500)
        #expect(history.reclaimedBytes(since: now.addingTimeInterval(-30 * day)) == 500)
    }

    @Test func growthComparesAgainstASnapshotOlderThanThePeriod() {
        var history = CleanupHistory()
        history.append(ScanSnapshot(date: now.addingTimeInterval(-10 * day), bytesByGroup: ["xcode": 1_000, "system": 900]))
        history.append(ScanSnapshot(date: now.addingTimeInterval(-3 * day), bytesByGroup: ["xcode": 9_000, "system": 900]))
        history.append(ScanSnapshot(date: now, bytesByGroup: ["xcode": 4_000, "system": 1_200, "docker": 700]))

        let growth = history.growth(over: 7 * day)
        #expect(growth.map(\.group) == [.xcode, .docker, .system])
        #expect(growth.map(\.bytes) == [3_000, 700, 300])
        #expect(history.growth(over: 30 * day).isEmpty)
    }

    @Test func persistsAndToleratesCorruptFiles() throws {
        let tree = try TemporaryTree()
        let store = CleanupHistoryStore(fileURL: tree.url("Support/ApolloKit/history.json"))
        #expect(store.load() == CleanupHistory())

        var history = CleanupHistory()
        history.append(CleanupRecord(date: now, source: .smartScan, removed: [try item("system.userCaches", 42)], movedToTrash: true))
        history.append(ScanSnapshot(date: now, bytesByGroup: ["system": 42]))
        try store.save(history)
        #expect(store.load() == history)

        try Data("not json".utf8).write(to: store.fileURL)
        #expect(store.load() == CleanupHistory())
    }
}
