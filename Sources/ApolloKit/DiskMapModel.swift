import ApolloKitCore
import AppKit
import Observation

@MainActor
@Observable
final class DiskMapModel {
    struct Result: Equatable {
        let removedCount: Int
        let reclaimedBytes: Int64
        let failures: [String]
    }

    private(set) var root: DiskNode?
    private(set) var scannedAt: Date?
    private(set) var isScanning = false
    private(set) var scannedBytes: Int64 = 0
    private(set) var scannedItemCount = 0
    private(set) var currentPath = ""

    /// The folder shown in the chart and list; `nil` means the root.
    private(set) var focusURL: URL?
    /// Picked for removal, in the order they were added.
    private(set) var collected: [DiskNode] = []
    private(set) var isRemoving = false
    private(set) var lastResult: Result?
    /// Called after every removal so the cleanup lands in the history.
    @ObservationIgnored var onClean: ((CleanupRecord) -> Void)?

    let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    @ObservationIgnored private let scanner = DiskMapScanner()
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    private var policy: SafetyPolicy { SafetyPolicy(homeDirectory: homeDirectory) }

    var focusedNode: DiskNode? {
        guard let root else { return nil }
        guard let focusURL else { return root }
        return root.node(at: focusURL) ?? root
    }

    var breadcrumbs: [DiskNode] {
        guard let root else { return [] }
        return root.path(to: focusURL ?? root.url)
    }

    var collectedBytes: Int64 {
        collected.reduce(0) { $0 + $1.bytes }
    }

    // MARK: - Scanning

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        lastResult = nil
        scannedBytes = 0
        scannedItemCount = 0
        let progress = DiskMapProgress()
        let scanner = scanner
        let home = homeDirectory

        scanTask = Task {
            let work = Task.detached { await scanner.scan(home, progress: progress) }
            let poller = Task {
                while !Task.isCancelled {
                    scannedBytes = progress.bytes
                    scannedItemCount = progress.itemCount
                    currentPath = progress.currentPath
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            let result = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            poller.cancel()

            isScanning = false
            // A cancelled scan is incomplete; keep the previous map rather than showing wrong sizes.
            guard !Task.isCancelled else { return }
            root = result
            scannedAt = .now
            if let focusURL, result.node(at: focusURL) == nil { self.focusURL = nil }
            collected = collected.compactMap { result.node(at: $0.url) }.filter(\.isRemovable)
        }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    // MARK: - Navigation

    func focus(_ node: DiskNode) {
        guard node.isDirectory else { return }
        focusURL = node.url
    }

    func goUp() {
        let crumbs = breadcrumbs
        guard crumbs.count > 1 else { return }
        focusURL = crumbs[crumbs.count - 2].url
    }

    // MARK: - Collecting

    /// Removable means a real item inside the home folder that the safety policy accepts
    /// (not the home folder, Documents, Library and the like).
    func canCollect(_ node: DiskNode) -> Bool {
        node.isRemovable && (try? policy.validate(node.url)) != nil
    }

    func isCollected(_ node: DiskNode) -> Bool {
        collected.contains { $0.id == node.id }
    }

    /// Inside a folder that is already collected, so it goes with it.
    func isIncludedByAncestor(_ node: DiskNode) -> Bool {
        collected.contains { node.url.path.hasPrefix($0.url.path + "/") }
    }

    func toggleCollected(_ node: DiskNode) {
        if isCollected(node) {
            collected.removeAll { $0.id == node.id }
            return
        }
        guard canCollect(node), !isIncludedByAncestor(node) else { return }
        // Collecting a folder replaces anything already collected inside it.
        collected.removeAll { $0.url.path.hasPrefix(node.url.path + "/") }
        collected.append(node)
        lastResult = nil
    }

    func clearCollected() {
        collected = []
    }

    func clean(mode: DeletionMode) {
        guard !isRemoving, !collected.isEmpty else { return }
        isRemoving = true
        let items = collected.map {
            CleanupItem(url: $0.url, rule: DiskMapScanner.removalRule, sizeInBytes: $0.bytes, lastModified: nil, displayName: $0.name)
        }
        let cleaner = Cleaner(policy: policy, fileUsage: FileUsageMonitor())

        Task {
            let outcome = await cleaner.clean(items, mode: mode)
            onClean?(CleanupRecord(source: .diskMap, removed: outcome.removed, movedToTrash: mode == .moveToTrash))
            let handled = Set((outcome.removed + outcome.missing).compactMap { $0.url?.path })
            root = root?.removing(handled)
            collected.removeAll { handled.contains($0.url.path) }
            lastResult = Result(
                removedCount: outcome.removed.count,
                reclaimedBytes: outcome.reclaimedBytes,
                failures: outcome.failures.map { "\($0.item.displayName): \($0.reason)" }
            )
            isRemoving = false
        }
    }

    // MARK: - Finder

    func reveal(_ node: DiskNode) {
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    func open(_ node: DiskNode) {
        NSWorkspace.shared.open(node.url)
    }
}
