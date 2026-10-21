import CoreServices
import Foundation

/// Where and how large files are searched for.
public struct LargeFileSearch: Sendable, Hashable {
    public static let defaultHomeRelativeRoots = ["Downloads", "Desktop", "Documents", "Movies"]
    public static let defaultMinimumBytes: Int64 = 100_000_000

    public let homeRelativeRoots: [String]
    public let minimumBytes: Int64

    public init(homeRelativeRoots: [String] = defaultHomeRelativeRoots, minimumBytes: Int64 = defaultMinimumBytes) {
        self.homeRelativeRoots = homeRelativeRoots
        self.minimumBytes = minimumBytes
    }
}

struct LargeFileBinding: Sendable {
    let extensions: Set<String>
    let rule: CleanupRule
}

/// Walks document folders for files at or above a size threshold.
///
/// Git repositories, project roots, hidden folders and app bundles are never entered: files there
/// belong to code or apps, not to forgotten downloads. Directories whose extension a rule names
/// (`.sparsebundle`, `.utm`, `.xcarchive`) are reported whole, whether or not macOS treats them as packages.
struct LargeFileFinder: Sendable {
    private let specificBindings: [LargeFileBinding]
    private let fallbackRule: CleanupRule?
    /// Extensions owned by specific rules across the whole catalog, enabled or not, so turning off
    /// e.g. Installers never lets `.dmg` files leak into the catch-all rule.
    private let claimedExtensions: Set<String>
    private let excludedPaths: Set<String>
    let minimumBytes: Int64
    let maximumDepth: Int
    let maximumIssuesPerRoot = 25

    private static let neverDescendNames: Set<String> = ["node_modules", "Pods", "DerivedData"]
    private static let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
    ]

    init(
        bindings: [LargeFileBinding],
        claimedExtensions: Set<String>,
        minimumBytes: Int64,
        excludedDirectories: [URL],
        maximumDepth: Int = 10
    ) {
        self.specificBindings = bindings.filter { !$0.extensions.isEmpty }
        self.fallbackRule = bindings.first { $0.extensions.isEmpty }?.rule
        self.claimedExtensions = claimedExtensions
        self.excludedPaths = Set(excludedDirectories.map(\.standardizedFileURL.path))
        self.minimumBytes = minimumBytes
        self.maximumDepth = maximumDepth
    }

    func find(in root: URL, progress: @Sendable (ScanProgress) -> Void) -> LocateResult {
        var result = LocateResult()
        guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              let enumerator = FileManager.default.enumerator(
                  at: root,
                  includingPropertiesForKeys: Array(Self.keys),
                  options: [.skipsHiddenFiles, .skipsPackageDescendants],
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
            guard let values = try? url.resourceValues(forKeys: Self.keys), values.isSymbolicLink != true else {
                continue
            }
            let fileExtension = url.pathExtension.lowercased()

            if values.isDirectory == true {
                visited += 1
                if visited % 500 == 0 {
                    progress(.walking(directory: url.path, visited: visited))
                }
                if let rule = specificRule(forExtension: fileExtension) {
                    // Size is only known after measuring; the scanner drops bundles under the threshold.
                    result.candidates.append(ScanCandidate(url: url, rule: rule))
                    enumerator.skipDescendants()
                } else if values.isPackage == true
                            || enumerator.level >= maximumDepth
                            || Self.neverDescendNames.contains(url.lastPathComponent)
                            || excludedPaths.contains(url.standardizedFileURL.path)
                            || isRepository(url) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values.isRegularFile == true else { continue }
            let bytes = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            guard bytes >= minimumBytes,
                  let rule = specificRule(forExtension: fileExtension)
                    ?? (claimedExtensions.contains(fileExtension) ? nil : fallbackRule) else {
                continue
            }
            result.candidates.append(ScanCandidate(url: url, rule: rule))
        }
        return result
    }

    private func specificRule(forExtension fileExtension: String) -> CleanupRule? {
        guard !fileExtension.isEmpty else { return nil }
        return specificBindings.first { $0.extensions.contains(fileExtension) }?.rule
    }

    private func isRepository(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path)
    }

    /// When the file was last opened according to Spotlight, falling back to its modification date.
    /// Spotlight's date is preferred because opening a file does not change its modification date.
    static func lastUsedDate(of url: URL, modified: Date?) -> Date? {
        var lastUsed: Date?
        if let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) {
            lastUsed = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
        }
        return [lastUsed, modified].compactMap { $0 }.max()
    }
}
