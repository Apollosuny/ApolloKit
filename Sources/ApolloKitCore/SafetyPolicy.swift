import Foundation

/// Last line of defence before anything is removed. Every item is re-validated at clean time,
/// independently of how it was discovered.
public struct SafetyPolicy: Sendable {
    public enum Violation: Error, Equatable, LocalizedError {
        case outsideAllowedRoots(String)
        case protectedLocation(String)
        case excludedByUser(String)

        public var errorDescription: String? {
            switch self {
            case .outsideAllowedRoots(let path): "Refused: \(path) is outside your home folder and scan locations."
            case .protectedLocation(let path): "Refused: \(path) is a protected location."
            case .excludedByUser(let path): "Refused: \(path) is on your Never Clean list, or contains something that is."
            }
        }
    }

    private static let protectedHomeRelativePaths = [
        "Library", "Library/Caches", "Library/Logs", "Library/Developer", "Library/Developer/Xcode",
        "Library/Application Support", "Library/Containers", "Library/Group Containers", "Library/Mobile Documents",
        "Library/Application Support/MobileSync", "Library/Android", "Library/Android/sdk",
        ".cache", ".rustup", ".rustup/toolchains", ".nvm", ".pyenv", ".rbenv", ".gradle", ".docker",
        "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", "Applications",
        ".Trash", ".ssh", ".gnupg", ".config", ".aws", ".kube",
    ]

    private let allowedRoots: [String]
    private let protectedPaths: Set<String>
    private let excludedPaths: [String]

    /// - Parameter excludedPaths: the user's Never Clean list. Neither these paths, anything inside them,
    ///   nor any folder containing them can be removed.
    public init(homeDirectory: URL, additionalAllowedRoots: [URL] = [], excludedPaths: [URL] = []) {
        let home = Self.canonicalPath(homeDirectory)
        let extraRoots = additionalAllowedRoots.map(Self.canonicalPath)
        self.allowedRoots = [home] + extraRoots
        self.protectedPaths = Set(
            ["/", home] + extraRoots + Self.protectedHomeRelativePaths.map { home + "/" + $0 }
        )
        self.excludedPaths = excludedPaths.map(Self.canonicalPath)
    }

    public func isExcludedByUser(_ url: URL) -> Bool {
        let path = Self.canonicalPath(url)
        return excludedPaths.contains { $0 == path || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }
    }

    public func validate(_ url: URL) throws {
        let path = Self.canonicalPath(url)
        guard allowedRoots.contains(where: { path.hasPrefix($0 + "/") }) else {
            throw Violation.outsideAllowedRoots(path)
        }
        if protectedPaths.contains(path) || protectedPaths.contains(where: { $0.hasPrefix(path + "/") }) {
            throw Violation.protectedLocation(path)
        }
        if isExcludedByUser(url) {
            throw Violation.excludedByUser(path)
        }
    }

    /// Resolves symlinks in the parent chain but not the item itself, so removing a symlink
    /// only ever removes the link, while a symlinked parent cannot smuggle a path out of bounds.
    static func canonicalPath(_ url: URL) -> String {
        let standardized = url.standardizedFileURL
        let parent = standardized.deletingLastPathComponent().resolvingSymlinksInPath()
        let path = parent.appendingPathComponent(standardized.lastPathComponent).path
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
