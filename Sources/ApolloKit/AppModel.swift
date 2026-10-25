import ApolloKitCore
import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case idle
        case scanning(status: String)
        case cleaning(completed: Int, total: Int)
    }

    private(set) var phase: Phase = .idle
    private(set) var report: ScanReport?
    private(set) var lastOutcome: CleanupOutcome?
    var selectedItemIDs: Set<CleanupItem.ID> = []
    var errorMessage: String?
    /// The completion screen is shown after a cleanup until the user moves on.
    var showsCompletion = false

    private(set) var diskSpace = DiskSpace.current()
    /// Reclaimable bytes found so far, streamed while a scan runs.
    private(set) var liveBytesByGroup: [RuleGroup: Int64] = [:]
    /// Determinate progress once the scan is measuring; `nil` while it is still locating items.
    private(set) var scanFraction: Double?
    private(set) var cleaningItemName: String?

    let preferences = Preferences()
    let uninstaller = UninstallerModel()
    let startupItems = StartupItemsModel()
    let history = HistoryModel()
    let ports = PortsModel()
    let diskMap = DiskMapModel()
    let systemData = SystemDataModel()
    let notifier = Notifier()

    /// A screen the menu bar asked the main window to show; consumed by `ContentView`.
    var requestedSidebarSelection: SidebarSelection?

    /// Opens the main window; set by any live SwiftUI view, since only views can reach `openWindow`.
    @ObservationIgnored var openMainWindow: (() -> Void)?
    /// Set once at launch when the app should start in the menu bar without its window.
    @ObservationIgnored private(set) var hidesWindowAtLaunch = false
    @ObservationIgnored private var wasDiskSpaceLow = false
    @ObservationIgnored private var pendingLowSpaceAlert = false
    /// A background scan keeps the user on their current screen.
    private(set) var isBackgroundScan = false

    @ObservationIgnored private var activeTask: Task<Void, Never>?
    private let homeDirectory = FileManager.default.homeDirectoryForCurrentUser

    var isBusy: Bool { phase != .idle }

    init() {
        hidesWindowAtLaunch = preferences.startsInMenuBar && preferences.showsMenuBarExtra
        notifier.onOpen = { [weak self] in self?.showMainWindow() }
        uninstaller.onUninstall = { [weak self] record in self?.history.record(record) }
        diskMap.onClean = { [weak self] record in self?.history.record(record) }
        checkLowDiskSpace()

        // Keeps the menu bar's free-space readout current while the app sits in the background.
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                self.refreshDiskSpace()
            }
        }
    }

    func refreshDiskSpace() {
        diskSpace = DiskSpace.current()
        checkLowDiskSpace()
    }

    var isDiskSpaceLow: Bool {
        guard let diskSpace else { return false }
        return LowSpaceAlertPolicy(thresholdBytes: preferences.lowDiskSpaceThresholdBytes)
            .isLow(availableBytes: diskSpace.availableBytes)
    }

    func consumeHideWindowAtLaunch() -> Bool {
        defer { hidesWindowAtLaunch = false }
        return hidesWindowAtLaunch
    }

    func showMainWindow() {
        AppActivation.bringToFront()
        openMainWindow?()
    }

    private func checkLowDiskSpace() {
        guard let diskSpace else { return }
        let policy = LowSpaceAlertPolicy(thresholdBytes: preferences.lowDiskSpaceThresholdBytes)
        defer { wasDiskSpaceLow = policy.isLow(availableBytes: diskSpace.availableBytes) }
        guard preferences.warnsWhenDiskSpaceLow,
              policy.shouldAlert(availableBytes: diskSpace.availableBytes, wasLow: wasDiskSpaceLow, lastAlertAt: preferences.lastLowSpaceAlertAt)
        else { return }

        preferences.lastLowSpaceAlertAt = .now
        let reportIsStale = report.map { Date.now.timeIntervalSince($0.finishedAt) > 6 * 60 * 60 } ?? true
        if preferences.scansWhenDiskSpaceLow, reportIsStale, !isBusy {
            // The alert goes out when the scan finishes, with an estimate of what can be cleaned.
            pendingLowSpaceAlert = true
            startScan(inBackground: true)
        } else {
            postLowSpaceAlert()
        }
    }

    private func postLowSpaceAlert() {
        guard let available = diskSpace?.availableBytes else { return }
        let reclaimable = report.map { report in
            report.items.filter { $0.risk == .safe }.reduce(0) { $0 + $1.sizeInBytes }
        }
        let notifier = notifier
        Task { await notifier.postLowSpace(availableBytes: available, reclaimableBytes: reclaimable) }
    }

    // MARK: - Derived state

    func items(in group: RuleGroup) -> [CleanupItem] {
        report?.items.filter { $0.rule.group == group } ?? []
    }

    func totalBytes(in group: RuleGroup) -> Int64 {
        items(in: group).reduce(0) { $0 + $1.sizeInBytes }
    }

    var selectedItems: [CleanupItem] {
        report?.items.filter { selectedItemIDs.contains($0.id) } ?? []
    }

    var selectedBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.sizeInBytes }
    }

    var liveTotalBytes: Int64 {
        liveBytesByGroup.values.reduce(0, +)
    }

    /// Groups with findings, largest first.
    var groupsWithFindings: [RuleGroup] {
        RuleGroup.allCases
            .filter { totalBytes(in: $0) > 0 }
            .sorted { totalBytes(in: $0) > totalBytes(in: $1) }
    }

    func selectedBytes(in group: RuleGroup) -> Int64 {
        items(in: group).filter { selectedItemIDs.contains($0.id) }.reduce(0) { $0 + $1.sizeInBytes }
    }

    var permissionIssueCount: Int {
        report?.issues.filter(\.isPermissionDenied).count ?? 0
    }

    func selectionBinding(for item: CleanupItem) -> Binding<Bool> {
        Binding(
            get: { self.selectedItemIDs.contains(item.id) },
            set: { isSelected in
                if isSelected {
                    self.selectedItemIDs.insert(item.id)
                } else {
                    self.selectedItemIDs.remove(item.id)
                }
            }
        )
    }

    func select(_ items: [CleanupItem], _ isSelected: Bool) {
        let ids = items.map(\.id)
        if isSelected {
            selectedItemIDs.formUnion(ids)
        } else {
            selectedItemIDs.subtract(ids)
        }
    }

    // MARK: - Actions

    func startScan(inBackground: Bool = false) {
        guard !isBusy else { return }
        isBackgroundScan = inBackground
        phase = .scanning(status: "Preparing…")
        lastOutcome = nil
        showsCompletion = false
        liveBytesByGroup = [:]
        scanFraction = nil

        let scanner = DiskScanner(
            homeDirectory: homeDirectory,
            largeFileSearch: LargeFileSearch(minimumBytes: preferences.largeFileMinimumBytes),
            fileUsage: FileUsageMonitor()
        )
        let enabledRuleIDs = preferences.enabledRuleIDs
        let projectRoots = preferences.projectRoots

        activeTask = Task {
            do {
                let report = try await scanner.scan(enabledRuleIDs: enabledRuleIDs, projectRoots: projectRoots) { [weak self] progress in
                    Task { @MainActor in self?.apply(progress) }
                }
                self.report = report
                history.record(ScanSnapshot(report: report))
                // Pre-select only items that tools regenerate on their own.
                selectedItemIDs = Set(report.items.filter { $0.risk == .safe }.map(\.id))
            } catch is CancellationError {
                // Keep the previous report when the user cancels.
            } catch {
                errorMessage = error.localizedDescription
            }
            diskSpace = DiskSpace.current()
            phase = .idle
            isBackgroundScan = false
            activeTask = nil
            if pendingLowSpaceAlert {
                pendingLowSpaceAlert = false
                postLowSpaceAlert()
            }
        }
    }

    func clean(mode: DeletionMode) {
        guard !isBusy else { return }
        let items = selectedItems
        guard !items.isEmpty else { return }

        let cleaner = Cleaner(policy: SafetyPolicy(
            homeDirectory: homeDirectory,
            additionalAllowedRoots: preferences.projectRoots
        ), fileUsage: FileUsageMonitor())
        phase = .cleaning(completed: 0, total: items.count)
        cleaningItemName = items.first?.displayName
        let itemNames = items.map(\.displayName)

        activeTask = Task {
            let outcome = await cleaner.clean(items, mode: mode) { [weak self] completed, total in
                Task { @MainActor in
                    guard let self, case .cleaning = self.phase else { return }
                    self.phase = .cleaning(completed: completed, total: total)
                    self.cleaningItemName = completed < itemNames.count ? itemNames[completed] : nil
                }
            }
            let handledIDs = Set((outcome.removed + outcome.missing).map(\.id))
            report?.items.removeAll { handledIDs.contains($0.id) }
            selectedItemIDs.subtract(handledIDs)
            lastOutcome = outcome
            history.record(CleanupRecord(source: .smartScan, removed: outcome.removed, movedToTrash: mode == .moveToTrash))
            showsCompletion = true
            cleaningItemName = nil
            diskSpace = DiskSpace.current()
            phase = .idle
            activeTask = nil
        }
    }

    func cancel() {
        activeTask?.cancel()
    }

    /// Shows a Smart Scan group, scanning first when there are no results to show yet.
    func reviewInSmartScan(_ group: RuleGroup) {
        requestedSidebarSelection = .group(group)
        if report == nil { startScan() }
    }

    func revealInFinder(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    private func apply(_ progress: ScanProgress) {
        // Progress hops can arrive after the scan finished; never resurrect the scanning state.
        guard case .scanning = phase else { return }
        switch progress {
        case .locating(let ruleTitle):
            phase = .scanning(status: "Checking \(ruleTitle)…")
        case .walking(let directory, let visited):
            phase = .scanning(status: "Walking projects (\(visited.formatted()) folders) · \(directory)")
        case .measuring(let completed, let total):
            phase = .scanning(status: "Measuring \(completed) of \(total) items…")
            scanFraction = total > 0 ? Double(completed) / Double(total) : nil
        case .discovered(let group, let bytes):
            liveBytesByGroup[group, default: 0] += bytes
        }
    }
}

struct DiskSpace: Equatable {
    let totalBytes: Int64
    let availableBytes: Int64

    var usedBytes: Int64 { max(0, totalBytes - availableBytes) }
    var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }

    static func current() -> DiskSpace? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ])
        guard let total = values?.volumeTotalCapacity,
              let available = values?.volumeAvailableCapacityForImportantUsage else {
            return nil
        }
        return DiskSpace(totalBytes: Int64(total), availableBytes: available)
    }
}

extension CleanupItem {
    /// `Date?` is not `Comparable`, which `KeyPathComparator` requires for table sorting.
    var lastModifiedSortKey: Date { lastModified ?? .distantPast }
}
