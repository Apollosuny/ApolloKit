import ApolloKitCore
import Foundation
import Observation

@MainActor
@Observable
final class Preferences {
    private enum Key {
        /// The single list kept before detected and user-chosen folders were separated; migrated on launch.
        static let legacyProjectRoots = "projectRoots"
        static let addedProjectRoots = "addedProjectRoots"
        static let removedProjectRoots = "removedProjectRoots"
        static let disabledRuleIDs = "disabledRuleIDs"
        static let knownRuleIDs = "knownRuleIDs"
        static let showsMenuBarExtra = "showsMenuBarExtra"
        static let showsFreeSpaceInMenuBar = "showsFreeSpaceInMenuBar"
        static let largeFileMinimumBytes = "largeFileMinimumBytes"
        static let startsInMenuBar = "startsInMenuBar"
        static let warnsWhenDiskSpaceLow = "warnsWhenDiskSpaceLow"
        static let lowDiskSpaceThresholdBytes = "lowDiskSpaceThresholdBytes"
        static let scansWhenDiskSpaceLow = "scansWhenDiskSpaceLow"
        static let lastLowSpaceAlertAt = "lastLowSpaceAlertAt"
        static let excludedPaths = "excludedPaths"
        static let activeProjectDays = "activeProjectDays"
    }

    @ObservationIgnored private let defaults: UserDefaults

    private(set) var projectRootList: ProjectRootList {
        didSet {
            defaults.set(projectRootList.added.map(\.path), forKey: Key.addedProjectRoots)
            defaults.set(projectRootList.removed.map(\.path), forKey: Key.removedProjectRoots)
        }
    }

    var projectRoots: [URL] { projectRootList.roots }

    /// The Never Clean list: never offered for removal anywhere, and refused by the safety policy.
    var excludedPaths: [URL] {
        didSet { defaults.set(excludedPaths.map(\.path), forKey: Key.excludedPaths) }
    }

    /// Projects changed within this many days count as active: their build artifacts are not pre-selected.
    var activeProjectDays: Int {
        didSet { defaults.set(activeProjectDays, forKey: Key.activeProjectDays) }
    }

    var disabledRuleIDs: Set<String> {
        didSet { defaults.set(disabledRuleIDs.sorted(), forKey: Key.disabledRuleIDs) }
    }

    var showsMenuBarExtra: Bool {
        didSet { defaults.set(showsMenuBarExtra, forKey: Key.showsMenuBarExtra) }
    }

    var showsFreeSpaceInMenuBar: Bool {
        didSet { defaults.set(showsFreeSpaceInMenuBar, forKey: Key.showsFreeSpaceInMenuBar) }
    }

    var largeFileMinimumBytes: Int64 {
        didSet { defaults.set(largeFileMinimumBytes, forKey: Key.largeFileMinimumBytes) }
    }

    var startsInMenuBar: Bool {
        didSet { defaults.set(startsInMenuBar, forKey: Key.startsInMenuBar) }
    }

    var warnsWhenDiskSpaceLow: Bool {
        didSet { defaults.set(warnsWhenDiskSpaceLow, forKey: Key.warnsWhenDiskSpaceLow) }
    }

    var lowDiskSpaceThresholdBytes: Int64 {
        didSet { defaults.set(lowDiskSpaceThresholdBytes, forKey: Key.lowDiskSpaceThresholdBytes) }
    }

    var scansWhenDiskSpaceLow: Bool {
        didSet { defaults.set(scansWhenDiskSpaceLow, forKey: Key.scansWhenDiskSpaceLow) }
    }

    var lastLowSpaceAlertAt: Date? {
        didSet { defaults.set(lastLowSpaceAlertAt, forKey: Key.lastLowSpaceAlertAt) }
    }

    /// Read without an instance so the app delegate can decide whether closing the window quits the app.
    static func storedShowsMenuBarExtra(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: Key.showsMenuBarExtra) as? Bool ?? true
    }

    var enabledRuleIDs: Set<String> {
        Set(RuleCatalog.all.map(\.id)).subtracting(disabledRuleIDs)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showsMenuBarExtra = Self.storedShowsMenuBarExtra(in: defaults)
        showsFreeSpaceInMenuBar = defaults.object(forKey: Key.showsFreeSpaceInMenuBar) as? Bool ?? true
        startsInMenuBar = defaults.bool(forKey: Key.startsInMenuBar)
        warnsWhenDiskSpaceLow = defaults.object(forKey: Key.warnsWhenDiskSpaceLow) as? Bool ?? true
        lowDiskSpaceThresholdBytes = (defaults.object(forKey: Key.lowDiskSpaceThresholdBytes) as? NSNumber)?.int64Value
            ?? 20_000_000_000
        scansWhenDiskSpaceLow = defaults.object(forKey: Key.scansWhenDiskSpaceLow) as? Bool ?? true
        lastLowSpaceAlertAt = defaults.object(forKey: Key.lastLowSpaceAlertAt) as? Date
        activeProjectDays = defaults.object(forKey: Key.activeProjectDays) as? Int ?? 30
        excludedPaths = (defaults.stringArray(forKey: Key.excludedPaths) ?? []).map { URL(fileURLWithPath: $0) }
        largeFileMinimumBytes = (defaults.object(forKey: Key.largeFileMinimumBytes) as? NSNumber)?.int64Value
            ?? LargeFileSearch.defaultMinimumBytes
        let detected = ProjectRootDetector().detect()
        if let legacy = defaults.stringArray(forKey: Key.legacyProjectRoots) {
            projectRootList = ProjectRootList(migratingSavedRoots: legacy.map(Self.folderURL), detected: detected)
            defaults.removeObject(forKey: Key.legacyProjectRoots)
        } else {
            projectRootList = ProjectRootList(
                detected: detected,
                added: (defaults.stringArray(forKey: Key.addedProjectRoots) ?? []).map(Self.folderURL),
                removed: (defaults.stringArray(forKey: Key.removedProjectRoots) ?? []).map(Self.folderURL)
            )
        }
        // Rules added in a later version start from their own default instead of being implicitly enabled.
        let knownRuleIDs = Set(defaults.stringArray(forKey: Key.knownRuleIDs) ?? [])
        let newDefaultOffRuleIDs = RuleCatalog.all
            .filter { !$0.enabledByDefault && !knownRuleIDs.contains($0.id) }
            .map(\.id)
        disabledRuleIDs = Set(defaults.stringArray(forKey: Key.disabledRuleIDs) ?? []).union(newDefaultOffRuleIDs)
        defaults.set(RuleCatalog.all.map(\.id), forKey: Key.knownRuleIDs)
        defaults.set(disabledRuleIDs.sorted(), forKey: Key.disabledRuleIDs)
    }

    func addProjectRoots(_ urls: [URL]) {
        projectRootList.add(urls)
    }

    func removeProjectRoots(_ urls: [URL]) {
        projectRootList.remove(urls)
    }

    /// Picks up checkout folders created since launch; cheap enough to run before every scan.
    func refreshDetectedProjectRoots() {
        let detected = ProjectRootDetector().detect()
        if detected.map(\.standardizedFileURL) != projectRootList.detected {
            projectRootList.updateDetected(detected)
        }
    }

    private static func folderURL(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    func addExclusions(_ urls: [URL]) {
        let existing = Set(excludedPaths.map(\.standardizedFileURL.path))
        let added = urls.map(\.standardizedFileURL).filter { !existing.contains($0.path) }
        excludedPaths = (excludedPaths + added).sorted { $0.path < $1.path }
    }

    func isEnabled(_ rule: CleanupRule) -> Bool {
        !disabledRuleIDs.contains(rule.id)
    }

    func setEnabled(_ enabled: Bool, for rule: CleanupRule) {
        if enabled {
            disabledRuleIDs.remove(rule.id)
        } else {
            disabledRuleIDs.insert(rule.id)
        }
    }
}
