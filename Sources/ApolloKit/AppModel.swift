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

    @ObservationIgnored private var activeTask: Task<Void, Never>?
    private let homeDirectory = FileManager.default.homeDirectoryForCurrentUser

    var isBusy: Bool { phase != .idle }

    init() {
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

    func startScan() {
        guard !isBusy else { return }
        phase = .scanning(status: "Preparing…")
        lastOutcome = nil
        showsCompletion = false
        liveBytesByGroup = [:]
        scanFraction = nil

        let scanner = DiskScanner(
            homeDirectory: homeDirectory,
            largeFileSearch: LargeFileSearch(minimumBytes: preferences.largeFileMinimumBytes)
        )
        let enabledRuleIDs = preferences.enabledRuleIDs
        let projectRoots = preferences.projectRoots

        activeTask = Task {
            do {
                let report = try await scanner.scan(enabledRuleIDs: enabledRuleIDs, projectRoots: projectRoots) { [weak self] progress in
                    Task { @MainActor in self?.apply(progress) }
                }
                self.report = report
                // Pre-select only items that tools regenerate on their own.
                selectedItemIDs = Set(report.items.filter { $0.rule.risk == .safe }.map(\.id))
            } catch is CancellationError {
                // Keep the previous report when the user cancels.
            } catch {
                errorMessage = error.localizedDescription
            }
            diskSpace = DiskSpace.current()
            phase = .idle
            activeTask = nil
        }
    }

    func clean(mode: DeletionMode) {
        guard !isBusy else { return }
        let items = selectedItems
        guard !items.isEmpty else { return }

        let cleaner = Cleaner(policy: SafetyPolicy(
            homeDirectory: homeDirectory,
            additionalAllowedRoots: preferences.projectRoots
        ))
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
    /// Under 10% free, macOS starts purging caches and updates may fail to install.
    var isLow: Bool { availableBytes < totalBytes / 10 }

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
