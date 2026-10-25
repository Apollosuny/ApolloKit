import Foundation

/// Guesses which top-level home folders hold source checkouts, for users who have not chosen project folders.
public struct ProjectRootDetector: Sendable {
    /// Conventional folder names for source checkouts, matched case-insensitively.
    private static let conventionalNames: Set<String> = [
        "workspace", "projects", "developer", "code", "dev", "src", "repos", "git", "github", "work", "sites",
    ]
    /// Standard macOS folders hold personal files, so they are never searched as a whole.
    private static let standardNames: Set<String> = [
        "applications", "desktop", "documents", "downloads", "library", "movies", "music", "pictures", "public",
    ]
    /// Standard folders where people keep checkouts; only their child folders that hold repositories are used.
    private static let searchedStandardNames: Set<String> = ["desktop", "documents"]
    /// `Folder/.git`, `Folder/repo/.git` and `Folder/group/repo/.git` count; deeper checkouts are too unusual to look for.
    private static let maximumRepositoryDepth = 3

    public let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    public func detect() -> [URL] {
        directories(in: homeDirectory)
            .flatMap { folder -> [URL] in
                let name = folder.lastPathComponent.lowercased()
                if Self.conventionalNames.contains(name) { return [folder] }
                if Self.searchedStandardNames.contains(name) {
                    return directories(in: folder).filter { containsRepository($0, depth: Self.maximumRepositoryDepth) }
                }
                if Self.standardNames.contains(name) { return [] }
                return containsRepository(folder, depth: Self.maximumRepositoryDepth) ? [folder] : []
            }
            .sorted { $0.path < $1.path }
    }

    private func containsRepository(_ folder: URL, depth: Int) -> Bool {
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) { return true }
        guard depth > 1 else { return false }
        return directories(in: folder).contains { containsRepository($0, depth: depth - 1) }
    }

    /// Real child directories only: symlinks and app or document packages are skipped.
    private func directories(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        let children = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []
        return children.filter { child in
            guard let values = try? child.resourceValues(forKeys: Set(keys)) else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true && values.isPackage != true
                && child.lastPathComponent != "node_modules"
        }
    }
}

/// The project folders to search: those detected on this Mac, plus folders the user added, minus folders they removed.
///
/// Detection runs again on every launch, so a new checkout folder is picked up even after the user edited the list.
public struct ProjectRootList: Sendable, Equatable {
    public private(set) var detected: [URL]
    public private(set) var added: [URL]
    /// Detected folders the user removed; remembered so detection does not bring them back.
    public private(set) var removed: [URL]

    public init(detected: [URL], added: [URL] = [], removed: [URL] = []) {
        self.detected = detected.map(\.standardizedFileURL)
        self.added = added.map(\.standardizedFileURL)
        self.removed = removed.map(\.standardizedFileURL)
    }

    /// Carries over a list saved before detection and user edits were kept apart: whatever it
    /// lacks of today's detection was removed by the user, and whatever it adds was added by them.
    public init(migratingSavedRoots saved: [URL], detected: [URL]) {
        let saved = saved.map(\.standardizedFileURL)
        let detected = detected.map(\.standardizedFileURL)
        self.init(
            detected: detected,
            added: saved.filter { !detected.contains($0) },
            removed: detected.filter { !saved.contains($0) }
        )
    }

    public var roots: [URL] {
        var seen = Set<String>()
        return (detected.filter { !removed.contains($0) } + added)
            .filter { seen.insert($0.path).inserted }
            .sorted { $0.path < $1.path }
    }

    public func isDetected(_ url: URL) -> Bool {
        detected.contains(url.standardizedFileURL)
    }

    public mutating func updateDetected(_ urls: [URL]) {
        detected = urls.map(\.standardizedFileURL)
    }

    public mutating func add(_ urls: [URL]) {
        for url in urls.map(\.standardizedFileURL) {
            removed.removeAll { $0 == url }
            if !detected.contains(url), !added.contains(url) { added.append(url) }
        }
    }

    public mutating func remove(_ urls: [URL]) {
        for url in urls.map(\.standardizedFileURL) {
            added.removeAll { $0 == url }
            if detected.contains(url), !removed.contains(url) { removed.append(url) }
        }
    }
}
