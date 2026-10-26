import CoreServices
import Foundation

/// Finds Library data of apps that are no longer installed, without a list of known apps.
///
/// Only data that is clearly an app's is considered: folders named after a bundle identifier, and
/// Electron app folders in Application Support. Anything an installed app could own, anything written
/// recently, and anything of Apple's is left alone, since command-line tools and system services keep
/// folders in the same places.
struct AppLeftoverFinder: Sendable {
    /// Library folders whose entries are named after the bundle identifier of the app that made them.
    /// Caches and Logs are left to their own rules, which already report every entry.
    static let bundleIdentifierLocations = [
        "Library/Application Support", "Library/Containers", "Library/HTTPStorages", "Library/WebKit",
        "Library/Saved Application State",
    ]
    /// Sandbox containers and saved window state belong to exactly one app, so another app of the same vendor does not claim them.
    static let exactOwnerLocations: Set<String> = ["Library/Containers", "Library/Saved Application State"]
    static let electronLocation = "Library/Application Support"
    /// Smaller leftovers are not worth a decision.
    static let minimumBytes: Int64 = 1_000_000
    /// Data written within this interval is still used by something, whatever its name suggests.
    static let inactivityInterval: TimeInterval = 30 * 24 * 60 * 60

    /// Bundle identifier components too generic to tie a folder to an app.
    private static let genericIdentifierComponents: Set<String> = [
        "app", "apps", "mac", "macos", "osx", "desktop", "client", "direct", "stable", "beta", "helper", "electron",
    ]
    private static let maximumActivityEntries = 20_000
    /// Rewritten when another program merely reads a database or opens a store, so they say nothing about use.
    private static let readSideEffectSuffixes = ["-shm", "-wal", "-journal", ".lock", "LOCK"]

    let homeDirectory: URL
    let installedApps: [InstalledApp]
    /// Whether an app with this bundle identifier exists anywhere, beyond the application folders searched.
    let isAppRegistered: @Sendable (String) -> Bool
    let now: Date

    init(
        homeDirectory: URL,
        installedApps: [InstalledApp],
        isAppRegistered: @escaping @Sendable (String) -> Bool = Self.launchServicesKnowsApp,
        now: Date = .now
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.installedApps = installedApps
        self.isAppRegistered = isAppRegistered
        self.now = now
    }

    func find() -> [URL] {
        let ownership = Ownership(apps: installedApps)
        var found: [URL] = []
        for location in Self.bundleIdentifierLocations {
            for entry in directories(in: location) {
                guard let identifier = Self.bundleIdentifier(fromEntryName: entry.lastPathComponent),
                      !ownership.owns(bundleIdentifier: identifier, sameVendorCounts: !Self.exactOwnerLocations.contains(location)),
                      !registeredPrefixes(of: identifier) else { continue }
                found.append(entry)
            }
        }
        for entry in directories(in: Self.electronLocation)
        where Self.bundleIdentifier(fromEntryName: entry.lastPathComponent) == nil
            && Self.isElectronData(entry)
            && !ownership.owns(folderName: entry.lastPathComponent) {
            found.append(entry)
        }
        return found.filter { !wasWrittenRecently($0) }
    }

    /// `com.example.app` from `com.example.app` or `com.example.app.savedState`; `nil` for names that are not
    /// a reverse-DNS identifier with at least three parts, or that belong to Apple.
    static func bundleIdentifier(fromEntryName name: String) -> String? {
        let identifier = name.hasSuffix(".savedState") ? String(name.dropLast(".savedState".count)) : name
        let components = identifier.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 3,
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }),
              components[0].first?.isLetter == true,
              !identifier.lowercased().hasPrefix("com.apple.") else { return nil }
        return identifier
    }

    /// Electron and other Chromium-based apps keep a profile with these at the top of their data folder.
    static func isElectronData(_ folder: URL) -> Bool {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: folder.appendingPathComponent("Local Storage").path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && fileManager.fileExists(atPath: folder.appendingPathComponent("Preferences").path)
    }

    static func launchServicesKnowsApp(_ bundleIdentifier: String) -> Bool {
        guard let urls = LSCopyApplicationURLsForBundleIdentifier(bundleIdentifier as CFString, nil)?
            .takeRetainedValue() as? [URL] else { return false }
        return urls.contains { FileManager.default.fileExists(atPath: $0.path) && !$0.path.contains("/.Trash/") }
    }

    /// `com.example.app.helper` may belong to an installed `com.example.app` that is outside the application folders.
    private func registeredPrefixes(of identifier: String) -> Bool {
        var components = identifier.split(separator: ".")
        while components.count >= 3 {
            if isAppRegistered(components.joined(separator: ".")) { return true }
            components.removeLast()
        }
        return false
    }

    private func wasWrittenRecently(_ folder: URL) -> Bool {
        let cutoff = now.addingTimeInterval(-Self.inactivityInterval)
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return true }
        var visited = 0
        while let url = enumerator.nextObject() as? URL, visited < Self.maximumActivityEntries {
            visited += 1
            let name = url.lastPathComponent
            guard !Self.readSideEffectSuffixes.contains(where: name.hasSuffix),
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            if let modified = values.contentModificationDate, modified > cutoff { return true }
        }
        return false
    }

    /// Real child directories only, so a symlink never leads the cleanup somewhere else.
    private func directories(in homeRelativePath: String) -> [URL] {
        let folder = homeDirectory.appendingPathComponent(homeRelativePath)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let children = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return children.filter { child in
            let values = try? child.resourceValues(forKeys: Set(keys))
            return values?.isDirectory == true && values?.isSymbolicLink != true
        }
        .map(\.standardizedFileURL)
    }

    /// What the installed apps could have named their data. Matching is deliberately loose:
    /// keeping a leftover costs disk space, removing an installed app's data costs the user's data.
    struct Ownership {
        let bundleIdentifiers: [String]
        let vendors: Set<String>
        /// Lowercased letters and digits of app names and distinctive identifier parts.
        let nameTokens: Set<String>

        init(apps: [InstalledApp]) {
            bundleIdentifiers = apps.map { $0.bundleIdentifier.lowercased() }
            vendors = Set(bundleIdentifiers.compactMap(Self.vendor))
            var tokens = Set<String>()
            for app in apps {
                tokens.insert(Self.normalized(app.name))
                tokens.insert(Self.normalized(app.url.deletingPathExtension().lastPathComponent))
                for component in app.bundleIdentifier.split(separator: ".").dropFirst()
                where component.count >= 4 && !AppLeftoverFinder.genericIdentifierComponents.contains(component.lowercased()) {
                    tokens.insert(Self.normalized(String(component)))
                }
            }
            nameTokens = tokens.filter { $0.count >= 3 }
        }

        /// The same identifier, one extending it (`.helper`, `TEAM.` prefixes), or, where shared data is common,
        /// another app of the same vendor.
        func owns(bundleIdentifier: String, sameVendorCounts: Bool) -> Bool {
            let identifier = bundleIdentifier.lowercased()
            if sameVendorCounts, let vendor = Self.vendor(identifier), vendors.contains(vendor) { return true }
            return bundleIdentifiers.contains { installed in
                identifier == installed || identifier.hasPrefix(installed + ".") || identifier.hasSuffix("." + installed)
                    || installed.hasPrefix(identifier + ".")
            }
        }

        /// Electron apps name the folder after the product, which may extend the app's name (`ZaloData`, `Docker Desktop`).
        func owns(folderName: String) -> Bool {
            let name = Self.normalized(folderName)
            guard name.count >= 3 else { return true }
            return nameTokens.contains { name.hasPrefix($0) || $0.hasPrefix(name) }
        }

        static func normalized(_ text: String) -> String {
            String(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
        }

        /// `com.example` from `com.example.app`.
        static func vendor(_ identifier: String) -> String? {
            let components = identifier.lowercased().split(separator: ".")
            guard components.count >= 3 else { return nil }
            return components.prefix(2).joined(separator: ".")
        }
    }
}
