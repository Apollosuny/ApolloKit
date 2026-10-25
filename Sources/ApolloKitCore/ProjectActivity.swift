import Foundation

/// A project folder holding build artifacts found by a scan, and when its own files last changed.
public struct ProjectSummary: Sendable, Hashable, Identifiable {
    public let root: URL
    /// Newest change to the project's files or git state, ignoring its build artifacts. `nil` when nothing could be read.
    public let lastActivity: Date?
    public let itemIDs: [CleanupItem.ID]

    public var id: String { root.path }
    public var name: String { root.lastPathComponent }

    public init(root: URL, lastActivity: Date?, itemIDs: [CleanupItem.ID]) {
        self.root = root
        self.lastActivity = lastActivity
        self.itemIDs = itemIDs
    }
}

/// Groups build artifacts by the project they belong to and reads when each project was last worked on.
///
/// Activity comes from source files and git state only: builds and installs rewrite the artifacts
/// themselves, and folder dates change when an artifact is removed, so neither says the project is in use.
struct ProjectActivityInspector: Sendable {
    let searchRoots: Set<String>
    let homeDirectory: URL
    /// Bounds the walk of very large projects; the newest date among the files read so far is used.
    let maximumEntries: Int

    private static let gitStateFiles = ["HEAD", "index", "logs/HEAD"]
    private static let neverDescendNames: Set<String> = ["node_modules", "Pods", "DerivedData"]

    init(searchRoots: [URL], homeDirectory: URL, maximumEntries: Int = 20_000) {
        self.searchRoots = Set(searchRoots.map(\.standardizedFileURL.path))
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.maximumEntries = maximumEntries
    }

    /// The nearest enclosing git checkout, so a monorepo's packages count as one project;
    /// otherwise the folder holding the artifact. Never climbs above a search root or into the home folder.
    func projectRoot(for artifact: URL) -> URL {
        let folder = artifact.standardizedFileURL.deletingLastPathComponent()
        var candidate = folder
        while candidate.path != homeDirectory.path, candidate.path != "/" {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent(".git").path) {
                return candidate
            }
            if searchRoots.contains(candidate.path) { break }
            candidate = candidate.deletingLastPathComponent()
        }
        return folder
    }

    func lastActivity(of root: URL, ignoring artifactPaths: Set<String>) -> Date? {
        var newest = gitActivity(of: root)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return newest
        }

        var visited = 0
        while let url = enumerator.nextObject() as? URL, visited < maximumEntries {
            visited += 1
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                  values.isSymbolicLink != true else {
                continue
            }
            if values.isDirectory == true {
                if Self.neverDescendNames.contains(url.lastPathComponent) || artifactPaths.contains(url.standardizedFileURL.path) {
                    enumerator.skipDescendants()
                }
                continue
            }
            if let modified = values.contentModificationDate, modified > (newest ?? .distantPast) {
                newest = modified
            }
        }
        return newest
    }

    /// Commits, checkouts and staging rewrite these; worktrees and submodules point elsewhere and are left to the file walk.
    private func gitActivity(of root: URL) -> Date? {
        let gitDirectory = root.appendingPathComponent(".git")
        return Self.gitStateFiles
            .compactMap { try? gitDirectory.appendingPathComponent($0).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .max()
    }
}
