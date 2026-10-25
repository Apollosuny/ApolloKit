import Foundation

public struct CleanupRecord: Codable, Sendable, Hashable, Identifiable {
    public enum Source: String, Codable, Sendable {
        case smartScan
        case uninstaller
        case diskMap
    }

    public var id = UUID()
    public let date: Date
    public let source: Source
    /// App name for uninstalls; `nil` for Smart Scan cleanups.
    public let title: String?
    public let itemCount: Int
    public let reclaimedBytes: Int64
    /// Keyed by `RuleGroup.rawValue` so records stay readable if groups are added later.
    public let bytesByGroup: [String: Int64]
    /// Moved to the Trash: the space is only freed once the Trash is emptied.
    public let movedToTrash: Bool
    /// Locations of the removed items, largest first, so a cleanup can be traced afterwards.
    /// `nil` in records written before paths were kept.
    public let locations: [String]?

    public init(
        date: Date = .now,
        source: Source,
        title: String? = nil,
        removed: [CleanupItem],
        movedToTrash: Bool
    ) {
        self.date = date
        self.source = source
        self.title = title
        self.itemCount = removed.count
        self.reclaimedBytes = removed.reduce(0) { $0 + $1.sizeInBytes }
        self.bytesByGroup = Dictionary(grouping: removed, by: \.rule.group.rawValue)
            .mapValues { $0.reduce(0) { $0 + $1.sizeInBytes } }
        self.movedToTrash = movedToTrash
        self.locations = removed
            .sorted { $0.sizeInBytes > $1.sizeInBytes }
            .prefix(Self.maximumLocations)
            .map(\.locationDescription)
    }

    /// Keeps the history file small even after cleaning thousands of project folders.
    public static let maximumLocations = 300
}

/// Reclaimable bytes per group at the end of a scan, used to see which caches grow fastest.
public struct ScanSnapshot: Codable, Sendable, Hashable {
    public let date: Date
    public let bytesByGroup: [String: Int64]

    public init(report: ScanReport) {
        self.date = report.finishedAt
        self.bytesByGroup = Dictionary(grouping: report.items, by: \.rule.group.rawValue)
            .mapValues { $0.reduce(0) { $0 + $1.sizeInBytes } }
    }

    init(date: Date, bytesByGroup: [String: Int64]) {
        self.date = date
        self.bytesByGroup = bytesByGroup
    }
}

public struct CleanupHistory: Codable, Sendable, Equatable {
    public static let maximumRecords = 500
    public static let maximumSnapshots = 200

    public private(set) var records: [CleanupRecord] = []
    public private(set) var snapshots: [ScanSnapshot] = []

    public init(records: [CleanupRecord] = [], snapshots: [ScanSnapshot] = []) {
        self.records = records
        self.snapshots = snapshots
    }

    public mutating func append(_ record: CleanupRecord) {
        guard record.itemCount > 0 else { return }
        records.append(record)
        records.sort { $0.date < $1.date }
        records = Array(records.suffix(Self.maximumRecords))
    }

    public mutating func append(_ snapshot: ScanSnapshot) {
        snapshots.append(snapshot)
        snapshots.sort { $0.date < $1.date }
        snapshots = Array(snapshots.suffix(Self.maximumSnapshots))
    }

    public var totalReclaimedBytes: Int64 {
        records.reduce(0) { $0 + $1.reclaimedBytes }
    }

    public func reclaimedBytes(since date: Date) -> Int64 {
        records.filter { $0.date >= date }.reduce(0) { $0 + $1.reclaimedBytes }
    }

    /// Growth per group between the latest snapshot and the newest one at least `period` older.
    /// Groups that shrank (usually because they were cleaned) are left out.
    public func growth(over period: TimeInterval) -> [(group: RuleGroup, bytes: Int64, since: Date)] {
        guard let latest = snapshots.last,
              let baseline = snapshots.last(where: { latest.date.timeIntervalSince($0.date) >= period }) else {
            return []
        }
        return RuleGroup.allCases.compactMap { group in
            let delta = (latest.bytesByGroup[group.rawValue] ?? 0) - (baseline.bytesByGroup[group.rawValue] ?? 0)
            return delta > 0 ? (group, delta, baseline.date) : nil
        }
        .sorted { $0.bytes > $1.bytes }
    }
}

/// Persists the history as JSON in Application Support.
public struct CleanupHistoryStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ApolloKit/history.json")
    }

    /// A missing or unreadable file yields an empty history rather than an error: history is informational.
    public func load() -> CleanupHistory {
        guard let data = try? Data(contentsOf: fileURL) else { return CleanupHistory() }
        return (try? Self.decoder.decode(CleanupHistory.self, from: data)) ?? CleanupHistory()
    }

    public func save(_ history: CleanupHistory) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(history).write(to: fileURL, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
