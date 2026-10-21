import ApolloKitCore
import AppKit
import Observation

@MainActor
@Observable
final class UninstallerModel {
    struct Result: Equatable {
        let appName: String
        let removedCount: Int
        let reclaimedBytes: Int64
        let failures: [String]
    }

    private(set) var apps: [InstalledApp] = []
    private(set) var appSizes: [InstalledApp.ID: Int64] = [:]
    private(set) var isLoadingApps = false

    var selectedAppID: InstalledApp.ID? {
        didSet { if selectedAppID != oldValue { inspectSelectedApp() } }
    }
    private(set) var footprint: [CleanupItem] = []
    private(set) var isLoadingFootprint = false
    var selectedItemIDs: Set<CleanupItem.ID> = []

    private(set) var isRemoving = false
    private(set) var lastResult: Result?
    private(set) var runningBundleIdentifiers: Set<String> = []
    /// Called after every removal so the cleanup lands in the history.
    @ObservationIgnored var onUninstall: ((CleanupRecord) -> Void)?

    @ObservationIgnored private let uninstaller = AppUninstaller()
    @ObservationIgnored private var sizeTask: Task<Void, Never>?
    @ObservationIgnored private var footprintTask: Task<Void, Never>?
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    private let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    private let ownBundleIdentifier = Bundle.main.bundleIdentifier

    init() {
        refreshRunningApps()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRunningApps() }
            })
        }
    }

    var selectedApp: InstalledApp? {
        apps.first { $0.id == selectedAppID }
    }

    var selectedItems: [CleanupItem] {
        footprint.filter { selectedItemIDs.contains($0.id) }
    }

    var selectedBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.sizeInBytes }
    }

    func isRunning(_ app: InstalledApp) -> Bool {
        runningBundleIdentifiers.contains(app.bundleIdentifier)
    }

    /// Apple's apps and ApolloKit itself are listed for reference but cannot be removed.
    func canRemove(_ app: InstalledApp) -> Bool {
        !app.isSystemApp && app.bundleIdentifier != ownBundleIdentifier
    }

    /// Bundles owned by root (typically App Store apps) usually need Finder or Launchpad to remove.
    func mayNeedAdministrator(_ app: InstalledApp) -> Bool {
        !FileManager.default.isWritableFile(atPath: app.url.path)
    }

    // MARK: - Loading

    func loadApps() {
        guard !isLoadingApps else { return }
        isLoadingApps = true
        sizeTask?.cancel()
        let uninstaller = uninstaller

        Task {
            let apps = await Task.detached { uninstaller.installedApps() }.value
            self.apps = apps
            isLoadingApps = false
            if let selectedAppID, !apps.contains(where: { $0.id == selectedAppID }) {
                self.selectedAppID = nil
            }
            measureSizes(of: apps.filter { appSizes[$0.id] == nil })
        }
    }

    private func measureSizes(of apps: [InstalledApp]) {
        sizeTask = Task {
            await withTaskGroup(of: (InstalledApp.ID, Int64).self) { group in
                var pending = apps.makeIterator()
                for _ in 0..<4 {
                    guard let app = pending.next() else { break }
                    group.addTask { (app.id, DirectorySizer.measure(app.url).allocatedBytes) }
                }
                while let (id, bytes) = await group.next() {
                    appSizes[id] = bytes
                    if Task.isCancelled { group.cancelAll(); break }
                    if let app = pending.next() {
                        group.addTask { (app.id, DirectorySizer.measure(app.url).allocatedBytes) }
                    }
                }
            }
        }
    }

    private func inspectSelectedApp() {
        footprintTask?.cancel()
        footprint = []
        selectedItemIDs = []
        lastResult = nil
        guard let app = selectedApp, canRemove(app) else {
            isLoadingFootprint = false
            return
        }

        isLoadingFootprint = true
        let uninstaller = uninstaller
        let others = Set(apps.map(\.bundleIdentifier))
        footprintTask = Task {
            let items = await Task.detached { uninstaller.footprint(of: app, otherBundleIdentifiers: others) }.value
            guard !Task.isCancelled, selectedAppID == app.id else { return }
            footprint = items
            // Name-only matches start unchecked; everything matched by bundle identifier is selected.
            selectedItemIDs = Set(items.filter { $0.rule.risk == .safe }.map(\.id))
            isLoadingFootprint = false
        }
    }

    private func refreshRunningApps() {
        runningBundleIdentifiers = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    // MARK: - Actions

    func select(_ items: [CleanupItem], _ isSelected: Bool) {
        if isSelected {
            selectedItemIDs.formUnion(items.map(\.id))
        } else {
            selectedItemIDs.subtract(items.map(\.id))
        }
    }

    func quit(_ app: InstalledApp) {
        NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier).forEach { $0.terminate() }
    }

    func uninstall(_ app: InstalledApp, mode: DeletionMode) {
        guard !isRemoving, canRemove(app), !isRunning(app) else { return }
        let items = selectedItems
        guard !items.isEmpty else { return }

        isRemoving = true
        // The bundle lives outside the home folder; allow exactly its parent folder for this cleanup.
        let cleaner = Cleaner(policy: SafetyPolicy(
            homeDirectory: homeDirectory,
            additionalAllowedRoots: [app.url.deletingLastPathComponent()]
        ))

        Task {
            let outcome = await cleaner.clean(items, mode: mode)
            onUninstall?(CleanupRecord(source: .uninstaller, title: app.name, removed: outcome.removed, movedToTrash: mode == .moveToTrash))
            let handled = Set((outcome.removed + outcome.missing).map(\.id))
            lastResult = Result(
                appName: app.name,
                removedCount: outcome.removed.count,
                reclaimedBytes: outcome.reclaimedBytes,
                failures: outcome.failures.map { "\($0.item.displayName): \($0.reason)" }
            )
            isRemoving = false

            if handled.contains(app.url.path) {
                let result = lastResult
                apps.removeAll { $0.id == app.id }
                appSizes[app.id] = nil
                selectedAppID = nil
                lastResult = result
            } else {
                footprint.removeAll { handled.contains($0.id) }
                selectedItemIDs.subtract(handled)
            }
        }
    }

    func revealInFinder(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
