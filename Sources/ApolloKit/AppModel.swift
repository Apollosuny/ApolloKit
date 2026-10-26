import ApolloKitCore
import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case idle
        case scanning(ScanStatus)
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
    /// Progress the scan has proven, plus how far it may drift until the next update; see `ScanEstimate`.
    private(set) var scanEstimate = ScanEstimate()
    private(set) var cleaningItemName: String?
    /// The running cleanup, kept until the next one so the completion screen can compare before and after.
    private(set) var cleaning: CleaningState?

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

    var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    var scanStatus: ScanStatus? {
        if case .scanning(let status) = phase { return status }
        return nil
    }

    init() {
        hidesWindowAtLaunch = preferences.startsInMenuBar && preferences.showsMenuBarExtra
        notifier.onOpen = { [weak self] in self?.showMainWindow() }
        uninstaller.onUninstall = { [weak self] record in self?.history.record(record) }
        diskMap.onClean = { [weak self] record in self?.history.record(record) }
        // Read through the closures so views that ask the tools observe changes to the list.
        diskMap.excludedPaths = { [preferences] in preferences.excludedPaths }
        uninstaller.excludedPaths = { [preferences] in preferences.excludedPaths }
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
        let reclaimable = report.map { _ in safeBytes }
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
        selectedItems(in: nil)
    }

    /// Selected items of one category, or of every category when `group` is `nil`.
    func selectedItems(in group: RuleGroup?) -> [CleanupItem] {
        report?.items.filter { selectedItemIDs.contains($0.id) && (group == nil || $0.rule.group == group) } ?? []
    }

    var selectedBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.sizeInBytes }
    }

    /// What can go without a second thought: the items selected for the user after a scan.
    var safeBytes: Int64 {
        report?.items.filter { $0.risk == .safe }.reduce(0) { $0 + $1.sizeInBytes } ?? 0
    }

    var cautionBytes: Int64 {
        report?.items.filter { $0.risk == .caution }.reduce(0) { $0 + $1.sizeInBytes } ?? 0
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

    /// Projects that still have build artifacts in the current results.
    var projects: [ProjectRow] {
        guard let report else { return [] }
        let itemsByID = Dictionary(uniqueKeysWithValues: report.items.map { ($0.id, $0) })
        let cutoff = Date.now.addingTimeInterval(-TimeInterval(preferences.activeProjectDays) * 24 * 60 * 60)
        return report.projects.compactMap { summary in
            let items = summary.itemIDs.compactMap { itemsByID[$0] }
            guard !items.isEmpty else { return nil }
            return ProjectRow(summary: summary, items: items, isStale: (summary.lastActivity ?? .distantPast) < cutoff)
        }
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
        phase = .scanning(ScanStatus(stage: .locating))
        lastOutcome = nil
        showsCompletion = false
        liveBytesByGroup = [:]
        scanEstimate = ScanEstimate(fraction: 0, ceiling: Self.locatingShare)

        let scanner = DiskScanner(
            homeDirectory: homeDirectory,
            largeFileSearch: LargeFileSearch(minimumBytes: preferences.largeFileMinimumBytes),
            fileUsage: FileUsageMonitor(),
            activeProjectWindow: TimeInterval(preferences.activeProjectDays) * 24 * 60 * 60
        )
        let enabledRuleIDs = preferences.enabledRuleIDs
        preferences.refreshDetectedProjectRoots()
        let projectRoots = preferences.projectRoots

        activeTask = Task {
            do {
                var report = try await scanner.scan(enabledRuleIDs: enabledRuleIDs, projectRoots: projectRoots) { [weak self] progress in
                    Task { @MainActor in self?.apply(progress) }
                }
                let policy = safetyPolicy
                report.items.removeAll { $0.fileURL.map(policy.isExcludedByUser) ?? false }
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

    /// Cleans the selection in one category, leaving other categories' selection for later, or everything when `group` is `nil`.
    func clean(mode: DeletionMode, in group: RuleGroup? = nil) {
        guard !isBusy else { return }
        // Category by category, so the cleaning screen can tick off whole categories as it goes.
        let groupOrder = Dictionary(uniqueKeysWithValues: RuleGroup.allCases.enumerated().map { ($1, $0) })
        let items = selectedItems(in: group).enumerated()
            .sorted { (groupOrder[$0.element.rule.group]!, $0.offset) < (groupOrder[$1.element.rule.group]!, $1.offset) }
            .map(\.element)
        guard !items.isEmpty else { return }

        let cleaner = Cleaner(policy: safetyPolicy, fileUsage: FileUsageMonitor())
        phase = .cleaning(completed: 0, total: items.count)
        cleaning = CleaningState(items: items, mode: mode, diskSpaceBefore: diskSpace)
        cleaningItemName = items.first?.displayName
        let itemNames = items.map(\.displayName)

        activeTask = Task {
            let outcome = await cleaner.clean(items, mode: mode) { [weak self] completed, total in
                Task { @MainActor in
                    guard let self, case .cleaning = self.phase else { return }
                    self.phase = .cleaning(completed: completed, total: total)
                    self.cleaning?.completed = completed
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

    private var safetyPolicy: SafetyPolicy {
        SafetyPolicy(
            homeDirectory: homeDirectory,
            additionalAllowedRoots: preferences.projectRoots,
            excludedPaths: preferences.excludedPaths
        )
    }

    /// Adds items to the Never Clean list and drops them, and anything they contain or sit in, from every tool.
    func neverClean(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        preferences.addExclusions(urls)
        let policy = safetyPolicy
        if let excluded = report?.items.filter({ $0.fileURL.map(policy.isExcludedByUser) ?? false }), !excluded.isEmpty {
            let ids = Set(excluded.map(\.id))
            report?.items.removeAll { ids.contains($0.id) }
            selectedItemIDs.subtract(ids)
        }
        diskMap.dropExcludedFromCollection()
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

    /// Shares of the progress ring: locating, then measuring, then the checks after it.
    private static let locatingShare = 0.1
    private static let measuringShare = 0.8

    private func apply(_ progress: ScanProgress) {
        // Progress hops can arrive after the scan finished; never resurrect the scanning state.
        guard case .scanning(var status) = phase else { return }
        switch progress {
        case .locating(let ruleTitle):
            guard status.stage == .locating else { return }
            status.currentItem = ruleTitle
        case .walking(let directory, _):
            guard status.stage == .locating else { return }
            status.currentItem = directory
        case .measuring(let completed, let total, let current):
            // Progress hops are separate tasks, so a late measuring update must not rewind the checks after it.
            guard status.stage == .locating || status.stage == .measuring, total > 0 else { return }
            if status.stage != .measuring {
                status.stage = .measuring
                status.stageStartedAt = .now
            }
            status.completed = completed
            status.total = total
            status.currentItem = current ?? status.currentItem
            let perItem = Self.measuringShare / Double(total)
            let base = Self.locatingShare
            scanEstimate = scanEstimate.advanced(to: base + perItem * Double(completed), ceiling: base + perItem * Double(min(total, completed + 1)))
        case .finishing(let step):
            status.stage = .finishing(step)
            status.stageStartedAt = .now
            status.currentItem = nil
            // Each check closes half the remaining gap, so the ring keeps moving without knowing how long a check takes.
            let checksShare = 1 - Self.locatingShare - Self.measuringShare
            let start = 1 - checksShare * pow(0.5, Double(step.rawValue))
            scanEstimate = scanEstimate.advanced(to: start, ceiling: 1 - checksShare * pow(0.5, Double(step.rawValue + 1)))
        case .discovered(let group, let bytes):
            liveBytesByGroup[group, default: 0] += bytes
            return
        }
        phase = .scanning(status)
    }
}

/// What a running scan is doing, for the scanning screen and the menu bar.
struct ScanStatus: Equatable {
    enum Stage: Equatable {
        case locating
        case measuring
        case finishing(FinishingStep)
    }

    var stage: Stage
    var stageStartedAt = Date.now
    /// Rule, folder or item the scan is busy with, when it reports one.
    var currentItem: String?
    var completed = 0
    var total = 0
}

/// Scan progress that never looks stalled: the view eases from `fraction` toward `ceiling`,
/// which the scan cannot pass before its next update.
struct ScanEstimate: Equatable {
    var fraction = 0.0
    var ceiling = 0.0
    var updatedAt = Date.now

    /// Covers most of the gap to the ceiling within a few seconds, then slows down without ever reaching it.
    func displayed(at date: Date) -> Double {
        let elapsed = max(0, date.timeIntervalSince(updatedAt))
        return fraction + (ceiling - fraction) * (1 - exp(-elapsed / 3))
    }

    /// Starts easing from what is on screen now, so an update that proves less than was shown never moves the ring back.
    func advanced(to fraction: Double, ceiling: Double, at date: Date = .now) -> ScanEstimate {
        let shown = displayed(at: date)
        return ScanEstimate(fraction: max(fraction, shown), ceiling: max(ceiling, shown), updatedAt: date)
    }
}

struct CleaningState {
    let items: [CleanupItem]
    let mode: DeletionMode
    let diskSpaceBefore: DiskSpace?
    var completed = 0

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.sizeInBytes } }
    /// Sizes of the items handled so far; items that fail are only known once the cleanup ends.
    var processedBytes: Int64 { items.prefix(completed).reduce(0) { $0 + $1.sizeInBytes } }

    var groups: [RuleGroup] {
        RuleGroup.allCases.filter { group in items.contains { $0.rule.group == group } }
    }

    func bytes(in group: RuleGroup) -> Int64 {
        items.filter { $0.rule.group == group }.reduce(0) { $0 + $1.sizeInBytes }
    }

    enum GroupProgress { case pending, running, done }

    func progress(of group: RuleGroup) -> GroupProgress {
        let indices = items.indices.filter { items[$0].rule.group == group }
        guard let last = indices.last, let first = indices.first else { return .pending }
        if completed > last { return .done }
        return completed >= first ? .running : .pending
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

struct ProjectRow: Identifiable {
    let summary: ProjectSummary
    let items: [CleanupItem]
    /// Not changed within the active-project window, or its activity could not be read.
    let isStale: Bool

    var id: String { summary.id }
    var name: String { summary.name }
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.sizeInBytes } }
    var lastActivitySortKey: Date { summary.lastActivity ?? .distantPast }
    var artifactNames: String {
        var seen = Set<String>()
        return items.sorted { $0.sizeInBytes > $1.sizeInBytes }
            .compactMap { $0.url?.lastPathComponent }
            .filter { seen.insert($0).inserted }
            .joined(separator: ", ")
    }
}

extension CleanupItem {
    /// `Date?` is not `Comparable`, which `KeyPathComparator` requires for table sorting.
    var lastModifiedSortKey: Date { lastModified ?? .distantPast }
}
