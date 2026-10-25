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
    case largeFiles

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
        case .largeFiles: "Large & Old Files"
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
        case .largeFiles: "archivebox"
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
    /// Files at or above the large-file threshold in the user's document folders, matched by
    /// lowercase extension. An empty set matches any file no other large-file rule claims.
    case largeFile(extensions: Set<String>)

    public static func dir(_ path: String) -> RuleLocator { .directory(homeRelativePath: path) }
    public static func children(_ path: String, label: String? = nil) -> RuleLocator {
        .childrenOf(homeRelativePath: path, label: label)
    }
    public static func largeFiles(_ extensions: String...) -> RuleLocator {
        .largeFile(extensions: Set(extensions))
    }
    public static func artifact(_ name: String, parent: [String] = [], content: [String] = []) -> RuleLocator {
        .projectArtifact(ArtifactPattern(directoryName: name, parentMarkers: parent, contentMarkers: content))
    }

    var homeRelativePath: String? {
        switch self {
        case .directory(let path), .childrenOf(let path, _), .leftover(let path, _): path
        case .eachChild, .toolchainVersions, .projectArtifact, .tool, .largeFile: nil
        }
    }

    var artifactPattern: ArtifactPattern? {
        if case .projectArtifact(let pattern) = self { return pattern }
        return nil
    }

    var largeFileExtensions: Set<String>? {
        if case .largeFile(let extensions) = self { return extensions }
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
    /// For catch-all locations whose owners are unknown (`~/Library/Caches`, `~/.cache`): items holding
    /// programs are raised to Caution, since command-line tools keep binaries and engines there too.
    public let inspectsForPrograms: Bool

    public init(
        id: String,
        title: String,
        detail: String,
        group: RuleGroup,
        risk: RiskLevel,
        locators: [RuleLocator],
        enabledByDefault: Bool = true,
        alwaysDeletePermanently: Bool = false,
        inspectsForPrograms: Bool = false
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.group = group
        self.risk = risk
        self.locators = locators
        self.enabledByDefault = enabledByDefault
        self.alwaysDeletePermanently = alwaysDeletePermanently
        self.inspectsForPrograms = inspectsForPrograms
    }
}

/// Something found about one item that makes it riskier than its rule says.
public enum CleanupConcern: Sendable, Hashable {
    /// A cache folder of unknown ownership that holds executables or libraries: a tool may run from it.
    case containsPrograms
    /// A toolchain version with command-line tools installed into it, which are removed along with it.
    case globalTools([String])
    /// Files inside were open in these processes when last checked.
    case inUse(processes: [String])
    /// A build artifact of a project whose files changed recently, so it is probably still being worked on.
    case activeProject(lastActivity: Date)

    public var summary: String {
        switch self {
        case .containsPrograms: "Contains programs"
        case .globalTools(let names): "Global tools: \(names.joined(separator: ", "))"
        case .inUse(let processes): "In use by \(processes.joined(separator: ", "))"
        case .activeProject: "Active project"
        }
    }

    public var explanation: String {
        switch self {
        case .containsPrograms:
            "Holds executables or libraries, so a command-line tool may run from here. It may stop working until it downloads them again."
        case .globalTools:
            "Command-line tools installed into this version (npm install -g) are removed with it and must be installed again."
        case .inUse:
            "A running app or tool has files open here. Quit it before cleaning."
        case .activeProject(let lastActivity):
            "The project was changed \(lastActivity.formatted(.relative(presentation: .named))). Removing this means reinstalling or rebuilding before you can run it again."
        }
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
    public var concerns: [CleanupConcern]

    public init(
        id: String,
        rule: CleanupRule,
        displayName: String,
        url: URL?,
        action: CleanupAction,
        sizeInBytes: Int64,
        lastModified: Date?,
        concerns: [CleanupConcern] = []
    ) {
        self.id = id
        self.rule = rule
        self.displayName = displayName
        self.url = url
        self.action = action
        self.sizeInBytes = sizeInBytes
        self.lastModified = lastModified
        self.concerns = concerns
    }

    /// A file-system item removed by moving it to the Trash or deleting it.
    public init(
        url: URL,
        rule: CleanupRule,
        sizeInBytes: Int64,
        lastModified: Date?,
        displayName: String? = nil,
        concerns: [CleanupConcern] = []
    ) {
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
            lastModified: lastModified,
            concerns: concerns
        )
    }

    /// The rule's risk, raised to Caution by anything found about this particular item.
    public var risk: RiskLevel {
        concerns.isEmpty ? rule.risk : .caution
    }

    /// Paths of file-system items; tool-based removals have none to check.
    public var fileURL: URL? {
        if case .removeItem(let url) = action { return url }
        return nil
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
    /// Projects whose build artifacts were found, with when each was last worked on.
    public let projects: [ProjectSummary]
    public let startedAt: Date
    public let finishedAt: Date

    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.sizeInBytes } }
}

public enum ScanProgress: Sendable, Equatable {
    case locating(ruleTitle: String)
    case walking(directory: String, visited: Int)
    /// `current` names an item still being measured, so a few large folders finishing last don't look like a stall.
    case measuring(completed: Int, total: Int, current: String?)
    /// Checks that run after every item is measured, before results are shown.
    case finishing(step: String)
    /// Emitted once per reported item so the UI can show reclaimable space while the scan runs.
    case discovered(group: RuleGroup, bytes: Int64)
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
