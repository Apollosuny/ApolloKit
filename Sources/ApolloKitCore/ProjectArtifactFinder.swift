import Foundation

struct ScanCandidate: Sendable {
    let url: URL
    let rule: CleanupRule
    var displayName: String? = nil
}

struct LocateResult: Sendable {
    var candidates: [ScanCandidate] = []
    var issues: [ScanIssue] = []
}

struct PatternBinding: Sendable {
    let pattern: ArtifactPattern
    let rule: CleanupRule
}

/// Walks project roots looking for build-artifact directories.
///
/// Matched directories are not descended into, so nested `node_modules` are never double counted.
/// Hidden directories (`.git`, `.idea`, …) are skipped unless their name is itself an artifact name.
struct ProjectArtifactFinder: Sendable {
    private let bindingsByName: [String: [PatternBinding]]
    private let excludedPaths: Set<String>
    let maximumDepth: Int
    let maximumIssuesPerRoot = 25

    private static let neverDescendNames: Set<String> = ["node_modules", "Pods", "DerivedData"]

    init(bindings: [PatternBinding], excludedDirectories: [URL], maximumDepth: Int = 12) {
        self.bindingsByName = Dictionary(grouping: bindings, by: \.pattern.directoryName)
        self.excludedPaths = Set(excludedDirectories.map(\.standardizedFileURL.path))
        self.maximumDepth = maximumDepth
    }

    func find(in root: URL, progress: @Sendable (ScanProgress) -> Void) -> LocateResult {
        var result = LocateResult()
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants],
            errorHandler: { url, error in
                if result.issues.count < maximumIssuesPerRoot {
                    result.issues.append(ScanIssue(url: url, error: error))
                }
                return true
            }
        ) else {
            return result
        }

        var visited = 0
        while let url = enumerator.nextObject() as? URL {
            if Task.isCancelled { break }
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else {
                continue
            }

            visited += 1
            if visited % 500 == 0 {
                progress(.walking(directory: url.path, visited: visited))
            }

            let name = url.lastPathComponent
            if let binding = bindingsByName[name]?.first(where: { $0.pattern.matches(url) }) {
                result.candidates.append(ScanCandidate(url: url, rule: binding.rule))
                enumerator.skipDescendants()
                continue
            }

            if enumerator.level >= maximumDepth
                || name.hasPrefix(".")
                || Self.neverDescendNames.contains(name)
                || excludedPaths.contains(url.standardizedFileURL.path) {
                enumerator.skipDescendants()
            }
        }
        return result
    }
}
