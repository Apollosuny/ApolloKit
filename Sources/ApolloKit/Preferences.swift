import ApolloKitCore
import Foundation
import Observation

@MainActor
@Observable
final class Preferences {
    private enum Key {
        static let projectRoots = "projectRoots"
        static let disabledRuleIDs = "disabledRuleIDs"
        static let knownRuleIDs = "knownRuleIDs"
        static let showsMenuBarExtra = "showsMenuBarExtra"
        static let showsFreeSpaceInMenuBar = "showsFreeSpaceInMenuBar"
        static let largeFileMinimumBytes = "largeFileMinimumBytes"
    }

    /// Conventional folder names for source checkouts, matched case-insensitively against the home folder.
    private static let conventionalProjectFolderNames: Set<String> = [
        "workspace", "projects", "developer", "code", "dev", "src", "repos", "git", "github", "work", "sites",
    ]

    @ObservationIgnored private let defaults: UserDefaults

    var projectRoots: [URL] {
        didSet { defaults.set(projectRoots.map(\.path), forKey: Key.projectRoots) }
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
        largeFileMinimumBytes = (defaults.object(forKey: Key.largeFileMinimumBytes) as? NSNumber)?.int64Value
            ?? LargeFileSearch.defaultMinimumBytes
        if let paths = defaults.stringArray(forKey: Key.projectRoots) {
            projectRoots = paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        } else {
            projectRoots = Self.detectProjectRoots()
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
        let existing = Set(projectRoots.map(\.standardizedFileURL.path))
        projectRoots += urls.filter { !existing.contains($0.standardizedFileURL.path) }
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

    private static func detectProjectRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let children = (try? FileManager.default.contentsOfDirectory(
            at: home,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return children
            .filter { conventionalProjectFolderNames.contains($0.lastPathComponent.lowercased()) }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.path < $1.path }
    }
}
