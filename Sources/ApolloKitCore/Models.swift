import Foundation

public enum RiskLevel: String, Sendable, CaseIterable {
    /// Regenerated automatically by the owning tool; removal only costs rebuild or re-download time.
    case safe
    /// Expensive to regenerate or may hold something worth keeping (archives, virtualenvs, emulator images).
    case caution
}

public enum RuleGroup: String, Sendable, CaseIterable, Identifiable {
    case system
    case apps
    case xcode
    case packageManagers
    case toolchains
    case editors
    case docker
    case projectArtifacts

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: "System"
        case .apps: "Browsers & Apps"
        case .xcode: "Xcode & Simulators"
        case .packageManagers: "Package Managers"
        case .toolchains: "Toolchains & Models"
        case .editors: "Editors & Tooling"
        case .docker: "Docker"
        case .projectArtifacts: "Project Build Artifacts"
        }
    }

    public var symbolName: String {
        switch self {
        case .system: "gearshape"
        case .apps: "macwindow"
        case .xcode: "hammer"
        case .packageManagers: "shippingbox"
        case .toolchains: "wrench.and.screwdriver"
        case .editors: "chevron.left.forwardslash.chevron.right"
        case .docker: "cube.box"
        case .projectArtifacts: "folder.badge.gearshape"
        }
    }
}

/// Describes a build-artifact directory inside a project tree.
///
/// Generic names such as `build` or `target` must be confirmed by marker files,
/// otherwise unrelated user folders with the same name would be reported.
public struct ArtifactPattern: Sendable, Hashable {
    public let directoryName: String
    /// At least one of these must exist next to the directory (e.g. `package.json` for `node_modules`).
    /// A `*.ext` marker matches any file with that extension (e.g. `*.csproj`).
    public let parentMarkers: [String]
    /// At least one of these must exist inside the directory (e.g. `pyvenv.cfg` for `.venv`).
    public let contentMarkers: [String]

    public init(directoryName: String, parentMarkers: [String] = [], contentMarkers: [String] = []) {
        self.directoryName = directoryName
        self.parentMarkers = parentMarkers
        self.contentMarkers = contentMarkers
    }

    public var hasMarkers: Bool { !parentMarkers.isEmpty || !contentMarkers.isEmpty }

    public func matches(_ directory: URL, fileManager: FileManager = .default) -> Bool {
        guard directory.lastPathComponent == directoryName else { return false }
        let parent = directory.deletingLastPathComponent()
        if !parentMarkers.isEmpty, !Self.containsAnyMarker(parentMarkers, in: parent, fileManager: fileManager) {
            return false
        }
        if !contentMarkers.isEmpty, !Self.containsAnyMarker(contentMarkers, in: directory, fileManager: fileManager) {
            return false
        }
        return true
    }

    private static func containsAnyMarker(_ markers: [String], in directory: URL, fileManager: FileManager) -> Bool {
        let exactMarkers = markers.filter { !$0.hasPrefix("*.") }
        if exactMarkers.contains(where: { fileManager.fileExists(atPath: directory.appendingPathComponent($0).path) }) {
            return true
        }
        let extensionMarkers = markers.filter { $0.hasPrefix("*.") }.map { String($0.dropFirst(1)) }
        guard !extensionMarkers.isEmpty,
              let entries = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return false
        }
        return entries.contains { entry in extensionMarkers.contains { entry.hasSuffix($0) } }
    }
}

public enum RuleLocator: Sendable, Hashable {
    /// The directory itself is a single cleanup item. Path is relative to the home directory.
    case directory(homeRelativePath: String)
    /// Each direct child becomes its own cleanup item. Path is relative to the home directory.
    /// `label` prefixes each child's display name when the bare folder name is ambiguous (e.g. NDK versions).
    case childrenOf(homeRelativePath: String, label: String?)
    /// Directories matching the pattern anywhere under the configured project roots.
    case projectArtifact(ArtifactPattern)
    /// For every child folder of the path (e.g. each browser profile), each existing subpath is one item.
    case eachChild(homeRelativePath: String, subpaths: [String], label: String)
    /// Installed versions of a toolchain manager; the active version is never reported.
    case toolchainVersions(ToolchainManager)
    /// Data left behind by an app; only reported when none of the app bundles is installed.
    case leftover(homeRelativePath: String, appBundleNames: [String])
    /// Items discovered and removed through an external tool (simctl, docker).
    case tool(ToolSource)

    public static func dir(_ path: String) -> RuleLocator { .directory(homeRelativePath: path) }
    public static func children(_ path: String, label: String? = nil) -> RuleLocator {
        .childrenOf(homeRelativePath: path, label: label)
    }
    public static func artifact(_ name: String, parent: [String] = [], content: [String] = []) -> RuleLocator {
        .projectArtifact(ArtifactPattern(directoryName: name, parentMarkers: parent, contentMarkers: content))
    }

    var homeRelativePath: String? {
        switch self {
        case .directory(let path), .childrenOf(let path, _), .leftover(let path, _): path
        case .eachChild, .toolchainVersions, .projectArtifact, .tool: nil
        }
    }

    var artifactPattern: ArtifactPattern? {
        if case .projectArtifact(let pattern) = self { return pattern }
        return nil
    }

    var toolSource: ToolSource? {
        if case .tool(let source) = self { return source }
        return nil
    }
}

public struct CleanupRule: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public let group: RuleGroup
    public let risk: RiskLevel
    public let locators: [RuleLocator]
    public let enabledByDefault: Bool
    /// Items that cannot meaningfully go to the Trash (e.g. the Trash itself).
    public let alwaysDeletePermanently: Bool

    public init(
        id: String,
        title: String,
        detail: String,
        group: RuleGroup,
        risk: RiskLevel,
        locators: [RuleLocator],
        enabledByDefault: Bool = true,
        alwaysDeletePermanently: Bool = false
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.group = group
        self.risk = risk
        self.locators = locators
        self.enabledByDefault = enabledByDefault
        self.alwaysDeletePermanently = alwaysDeletePermanently
    }
}

public enum CleanupAction: Sendable, Hashable {
    case removeItem(URL)
    case runTool(ToolInvocation)
}

public struct CleanupItem: Sendable, Hashable, Identifiable {
    public let id: String
    public let rule: CleanupRule
    public let displayName: String
    /// Filesystem location when the item maps to one (used for display and Reveal in Finder).
    public let url: URL?
    public let action: CleanupAction
    /// Allocated size on disk, or the owning tool's reclaimable estimate. Hard-linked or cloned
    /// files (pnpm, uv) are counted per link, so the real reclaimable space can be lower.
    public let sizeInBytes: Int64
    public let lastModified: Date?

    public init(
        id: String,
        rule: CleanupRule,
        displayName: String,
        url: URL?,
        action: CleanupAction,
        sizeInBytes: Int64,
        lastModified: Date?
    ) {
        self.id = id
        self.rule = rule
        self.displayName = displayName
        self.url = url
        self.action = action
        self.sizeInBytes = sizeInBytes
        self.lastModified = lastModified
    }

    /// A file-system item removed by moving it to the Trash or deleting it.
    public init(url: URL, rule: CleanupRule, sizeInBytes: Int64, lastModified: Date?, displayName: String? = nil) {
        let defaultName = rule.group == .projectArtifacts
            ? "\(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)"
            : url.lastPathComponent
        self.init(
            id: url.path,
            rule: rule,
            displayName: displayName ?? defaultName,
            url: url,
            action: .removeItem(url),
            sizeInBytes: sizeInBytes,
            lastModified: lastModified
        )
    }

    public var locationDescription: String {
        if let url { return url.path }
        if case .runTool(let invocation) = action { return invocation.commandLine }
        return displayName
    }

    /// Tool-based removals and Trash contents cannot be restored from the Trash.
    public var isAlwaysPermanent: Bool {
        if case .runTool = action { return true }
        return rule.alwaysDeletePermanently
    }
}

public struct ScanIssue: Sendable, Hashable, Identifiable {
    public let id = UUID()
    /// A path, or a tool name for issues that are not tied to a location.
    public let subject: String
    public let message: String
    public let isPermissionDenied: Bool

    public init(subject: String, message: String, isPermissionDenied: Bool = false) {
        self.subject = subject
        self.message = message
        self.isPermissionDenied = isPermissionDenied
    }

    public init(url: URL, message: String, isPermissionDenied: Bool) {
        self.init(subject: url.path, message: message, isPermissionDenied: isPermissionDenied)
    }

    init(url: URL, error: any Error) {
        self.init(
            url: url,
            message: error.localizedDescription,
            isPermissionDenied: FileErrorClassifier.isPermissionDenied(error)
        )
    }
}

public struct ScanReport: Sendable {
    public var items: [CleanupItem]
    public let issues: [ScanIssue]
    public let startedAt: Date
    public let finishedAt: Date

    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.sizeInBytes } }
}

public enum ScanProgress: Sendable, Equatable {
    case locating(ruleTitle: String)
    case walking(directory: String, visited: Int)
    case measuring(completed: Int, total: Int)
}

enum FileErrorClassifier {
    static func isPermissionDenied(_ error: any Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(nsError.code) {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain, [EPERM, EACCES].contains(Int32(nsError.code)) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isPermissionDenied(underlying)
        }
        return false
    }
}
