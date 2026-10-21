import CoreServices
import Foundation

public struct InstalledApp: Sendable, Hashable, Identifiable {
    public let url: URL
    public let bundleIdentifier: String
    public let name: String
    public let version: String?
    public let lastUsed: Date?

    public var id: String { url.path }

    /// Apple's own apps are part of the OS and are never offered for removal.
    public var isSystemApp: Bool {
        bundleIdentifier.hasPrefix("com.apple.") || url.path.hasPrefix("/System/")
    }

    public init?(bundleURL: URL) {
        guard let bundle = Bundle(url: bundleURL), let identifier = bundle.bundleIdentifier else { return nil }
        let info = bundle.infoDictionary ?? [:]
        self.url = bundleURL.standardizedFileURL
        self.bundleIdentifier = identifier
        self.name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent
        self.version = info["CFBundleShortVersionString"] as? String
        if let item = MDItemCreateWithURL(kCFAllocatorDefault, bundleURL as CFURL) {
            self.lastUsed = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
        } else {
            self.lastUsed = nil
        }
    }
}

/// Finds installed apps and everything they leave in the user's Library.
public struct AppUninstaller: Sendable {
    /// Rules attached to uninstall items. They are not part of `RuleCatalog.all`, so they never
    /// appear in Settings or in a Smart Scan.
    public enum Rules {
        public static let application = CleanupRule(
            id: "uninstall.application", title: "Application",
            detail: "The app bundle itself.",
            group: .apps, risk: .safe, locators: []
        )
        public static let appData = CleanupRule(
            id: "uninstall.appData", title: "App Data",
            detail: "Matched by the app's bundle identifier.",
            group: .apps, risk: .safe, locators: []
        )
        public static let possiblyRelated = CleanupRule(
            id: "uninstall.possiblyRelated", title: "Possibly Related",
            detail: "Matched by the app's name only. Check it belongs to this app before removing.",
            group: .apps, risk: .caution, locators: []
        )
    }

    /// Library folders whose entries are named after a bundle identifier
    /// (`com.example.app`, `com.example.app.plist`, `TEAMID.com.example.app`, `com.example.app.helper`).
    static let bundleIdentifierLocations = [
        "Library/Application Support", "Library/Caches", "Library/Preferences", "Library/Preferences/ByHost",
        "Library/Containers", "Library/Group Containers", "Library/Saved Application State", "Library/HTTPStorages",
        "Library/WebKit", "Library/Logs", "Library/LaunchAgents", "Library/Application Scripts", "Library/Cookies",
    ]

    /// Library folders where apps commonly use their display name instead of a bundle identifier.
    static let nameLocations = ["Library/Application Support", "Library/Caches", "Library/Logs"]

    public let homeDirectory: URL
    public let applicationDirectories: [URL]

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationDirectories: [URL]? = nil
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.applicationDirectories = applicationDirectories ?? [
            URL(fileURLWithPath: "/Applications"),
            homeDirectory.appendingPathComponent("Applications"),
        ]
    }

    /// Apps directly inside the application folders and one level of subfolders (e.g. `/Applications/Setapp`).
    public func installedApps() -> [InstalledApp] {
        var seen = Set<String>()
        var apps: [InstalledApp] = []
        for directory in applicationDirectories {
            for url in appBundles(in: directory, descendIntoFolders: true) {
                guard let app = InstalledApp(bundleURL: url), seen.insert(app.id).inserted else { continue }
                apps.append(app)
            }
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func appBundles(in directory: URL, descendIntoFolders: Bool) -> [URL] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return children.flatMap { child -> [URL] in
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { return [] }
            if child.pathExtension == "app" { return [child] }
            return descendIntoFolders ? appBundles(in: child, descendIntoFolders: false) : []
        }
    }

    /// The app bundle plus its Library data, measured. `otherBundleIdentifiers` are the other installed
    /// apps: data belonging to a related app (`com.google.Chrome.canary` when removing `com.google.Chrome`)
    /// is left alone.
    public func footprint(of app: InstalledApp, otherBundleIdentifiers: Set<String>) -> [CleanupItem] {
        var candidates: [(url: URL, rule: CleanupRule)] = [(app.url, Rules.application)]
        var seen: Set<String> = [app.url.path]
        let others = otherBundleIdentifiers.subtracting([app.bundleIdentifier])

        for location in Self.bundleIdentifierLocations {
            for child in children(of: location) where belongs(child.lastPathComponent, to: app.bundleIdentifier, others: others) {
                if seen.insert(child.path).inserted { candidates.append((child, Rules.appData)) }
            }
        }
        if app.name.count >= 3 {
            for location in Self.nameLocations {
                for child in children(of: location) where child.lastPathComponent.caseInsensitiveCompare(app.name) == .orderedSame {
                    if seen.insert(child.path).inserted { candidates.append((child, Rules.possiblyRelated)) }
                }
            }
        }

        return candidates.compactMap { candidate in
            let size = DirectorySizer.measure(candidate.url).allocatedBytes
            guard size > 0 || candidate.rule == Rules.application else { return nil }
            let modified = try? candidate.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return CleanupItem(
                url: candidate.url,
                rule: candidate.rule,
                sizeInBytes: size,
                lastModified: candidate.rule == Rules.application ? app.lastUsed : modified,
                displayName: displayName(for: candidate.url, rule: candidate.rule)
            )
        }
    }

    /// Whether a Library entry name refers to `bundleIdentifier`, but not to a longer identifier of another installed app.
    static func belongs(_ entryName: String, to bundleIdentifier: String, others: Set<String>) -> Bool {
        let matches = entryName == bundleIdentifier
            || entryName.hasPrefix(bundleIdentifier + ".")
            || entryName.hasSuffix("." + bundleIdentifier)
        guard matches else { return false }
        return !others.contains { other in
            other.count > bundleIdentifier.count
                && other.hasPrefix(bundleIdentifier + ".")
                && (entryName == other || entryName.hasPrefix(other + ".") || entryName.hasSuffix("." + other))
        }
    }

    private func belongs(_ entryName: String, to bundleIdentifier: String, others: Set<String>) -> Bool {
        Self.belongs(entryName, to: bundleIdentifier, others: others)
    }

    private func children(of homeRelativePath: String) -> [URL] {
        let directory = homeDirectory.appendingPathComponent(homeRelativePath)
        return ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .map(\.standardizedFileURL)
    }

    private func displayName(for url: URL, rule: CleanupRule) -> String {
        if rule == Rules.application { return url.lastPathComponent }
        // Keep the Library folder in the name: "Containers › com.example.app" says more than the bare identifier.
        var relative = String(url.path.dropFirst(homeDirectory.path.count + 1))
        if relative.hasPrefix("Library/") { relative.removeFirst("Library/".count) }
        return relative.split(separator: "/").joined(separator: " › ")
    }
}
