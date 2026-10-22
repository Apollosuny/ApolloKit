import Foundation

/// One entry in the disk map: a folder with its measured children, a file, an app-like package, or the
/// remainder of a folder's entries that were too small to keep individually.
public struct DiskNode: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case directory
        case file
        /// `.app`, `.photoslibrary`, … shown as one item, like Finder does.
        case package
        /// Entries below the size cut-off, merged so the tree stays small.
        case smallerItems(count: Int)
    }

    public let url: URL
    public let name: String
    public let kind: Kind
    public private(set) var bytes: Int64
    /// Sorted largest first.
    public private(set) var children: [DiskNode]
    /// Entries that could not be read, usually because of privacy protection (Full Disk Access).
    public let unreadableCount: Int

    public var id: String {
        if case .smallerItems = kind { return url.path + "/\u{0}smaller" }
        return url.path
    }

    public var isDirectory: Bool { kind == .directory }

    /// Real filesystem items, as opposed to the merged remainder.
    public var isRemovable: Bool {
        if case .smallerItems = kind { return false }
        return true
    }

    public init(url: URL, name: String? = nil, kind: Kind, bytes: Int64, children: [DiskNode] = [], unreadableCount: Int = 0) {
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.kind = kind
        self.bytes = bytes
        self.children = children
        self.unreadableCount = unreadableCount
    }

    /// The node for `target`, found by walking down from this node.
    public func node(at target: URL) -> DiskNode? {
        let targetPath = target.path
        var current = self
        while current.url.path != targetPath {
            guard let next = current.children.first(where: { child in
                guard child.isDirectory else { return false }
                let path = child.url.path
                return targetPath == path || targetPath.hasPrefix(path + "/")
            }) else {
                return nil
            }
            current = next
        }
        return current
    }

    /// Ancestors from this node down to `target`, both included.
    public func path(to target: URL) -> [DiskNode] {
        let targetPath = target.path
        var result = [self]
        var current = self
        while current.url.path != targetPath {
            guard let next = current.children.first(where: { child in
                let path = child.url.path
                return child.isDirectory && (targetPath == path || targetPath.hasPrefix(path + "/"))
            }) else {
                break
            }
            result.append(next)
            current = next
        }
        return result
    }

    /// A copy without the given items, with every ancestor's size reduced accordingly.
    public func removing(_ removedPaths: Set<String>) -> DiskNode {
        guard !removedPaths.isEmpty else { return self }
        var copy = self
        var keptChildren: [DiskNode] = []
        for child in children {
            if child.isRemovable, removedPaths.contains(child.url.path) { continue }
            let ownPath = child.url.path
            if child.isDirectory, removedPaths.contains(where: { $0.hasPrefix(ownPath + "/") }) {
                keptChildren.append(child.removing(removedPaths))
            } else {
                keptChildren.append(child)
            }
        }
        let removedBytes = children.reduce(0) { $0 + $1.bytes } - keptChildren.reduce(0) { $0 + $1.bytes }
        copy.children = keptChildren.sorted { $0.bytes > $1.bytes }
        copy.bytes -= removedBytes
        return copy
    }
}

/// Live counters for an ongoing scan, read by the UI on its own schedule.
public final class DiskMapProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var _bytes: Int64 = 0
    private var _itemCount = 0
    private var _currentPath = ""

    public init() {}

    public var bytes: Int64 { lock.withLock { _bytes } }
    public var itemCount: Int { lock.withLock { _itemCount } }
    public var currentPath: String { lock.withLock { _currentPath } }

    func add(bytes: Int64, items: Int, at path: String) {
        lock.withLock {
            _bytes += bytes
            _itemCount += items
            _currentPath = path
        }
    }
}

/// Measures a folder tree once and keeps only what is worth showing.
public struct DiskMapScanner: Sendable {
    /// Rule attached to items collected in the disk map; not part of `RuleCatalog.all`.
    public static let removalRule = CleanupRule(
        id: "diskMap.item", title: "Collected in Disk Map",
        detail: "A file or folder you picked in the disk map.",
        group: .largeFiles, risk: .caution, locators: []
    )

    /// Entries smaller than this are merged into "smaller items".
    public let minimumNodeBytes: Int64
    /// Largest entries kept per folder; the rest are merged.
    public let maximumChildren: Int
    /// Depth down to which subfolders are read concurrently. Deeper is faster but holds more pending work in memory.
    public let parallelDepth: Int

    public init(minimumNodeBytes: Int64 = 1_000_000, maximumChildren: Int = 200, parallelDepth: Int = 6) {
        self.minimumNodeBytes = minimumNodeBytes
        self.maximumChildren = maximumChildren
        self.parallelDepth = parallelDepth
    }

    public func scan(_ root: URL, progress: DiskMapProgress = DiskMapProgress()) async -> DiskNode {
        let root = root.standardizedFileURL
        var info = stat()
        let device: dev_t? = stat(root.path, &info) == 0 ? info.st_dev : nil
        return await scanDirectory(root, device: device, depth: 0, progress: progress)
    }

    private func scanDirectory(_ url: URL, device: dev_t?, depth: Int, progress: DiskMapProgress) async -> DiskNode {
        guard let entries = DirectoryReader.entries(atPath: url.path) else {
            return DiskNode(url: url, kind: .directory, bytes: 0, unreadableCount: 1)
        }

        // Files stay as name and size until `condense` decides which ones are worth a node.
        var files: [(name: String, bytes: Int64)] = []
        var directories: [(url: URL, isPackage: Bool)] = []
        for entry in entries {
            // Mounted volumes and firmlinks to other volumes are not part of this folder's usage.
            if let device, entry.device != device { continue }
            switch entry.kind {
            case .file:
                files.append((entry.name, entry.allocatedBytes))
            case .directory:
                // Built from the parent so every path in the tree keeps the root's spelling.
                let child = url.appendingPathComponent(entry.name, isDirectory: true)
                directories.append((child, Self.isPackage(child, name: entry.name)))
            case .symbolicLink, .other:
                continue
            }
        }
        progress.add(bytes: files.reduce(0) { $0 + $1.bytes }, items: files.count, at: url.path)

        var subdirectories: [DiskNode] = []
        if !Task.isCancelled {
            if depth < parallelDepth {
                await withTaskGroup(of: DiskNode.self) { group in
                    for directory in directories {
                        group.addTask { await scanChild(directory.url, isPackage: directory.isPackage, device: device, depth: depth, progress: progress) }
                    }
                    for await node in group { subdirectories.append(node) }
                }
            } else {
                for directory in directories {
                    subdirectories.append(await scanChild(directory.url, isPackage: directory.isPackage, device: device, depth: depth, progress: progress))
                }
            }
        }

        return condense(url: url, directories: subdirectories, files: files)
    }

    private func scanChild(_ url: URL, isPackage: Bool, device: dev_t?, depth: Int, progress: DiskMapProgress) async -> DiskNode {
        let node = await scanDirectory(url, device: device, depth: depth + 1, progress: progress)
        guard isPackage else { return node }
        return DiskNode(url: url, kind: .package, bytes: node.bytes, unreadableCount: node.unreadableCount)
    }

    /// Only folders with an extension can be packages; asking Launch Services for every folder is slow.
    private static func isPackage(_ url: URL, name: String) -> Bool {
        guard name.contains("."), !name.hasPrefix(".") else { return false }
        return (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }

    /// Keeps the largest entries and merges the rest, so a folder of 50,000 tiny files costs one node.
    func condense(url: URL, directories: [DiskNode], files: [(name: String, bytes: Int64)]) -> DiskNode {
        let total = directories.reduce(0) { $0 + $1.bytes } + files.reduce(0) { $0 + $1.bytes }
        let unreadable = directories.reduce(0) { $0 + $1.unreadableCount }

        let largeDirectories = directories.filter { $0.bytes >= minimumNodeBytes }
        let largeFiles = files.filter { $0.bytes >= minimumNodeBytes }
            .map { DiskNode(url: url.appendingPathComponent($0.name, isDirectory: false), kind: .file, bytes: $0.bytes) }
        let kept = Array((largeDirectories + largeFiles).sorted { $0.bytes > $1.bytes }.prefix(maximumChildren))

        var children = kept
        let restCount = directories.count + files.count - kept.count
        if restCount > 0 {
            let restBytes = total - kept.reduce(0) { $0 + $1.bytes }
            children.append(DiskNode(url: url, name: "\(restCount) smaller items", kind: .smallerItems(count: restCount), bytes: restBytes))
        }
        return DiskNode(url: url, kind: .directory, bytes: total, children: children, unreadableCount: unreadable)
    }
}
