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

    let preferences = Preferences()

    @ObservationIgnored private var activeTask: Task<Void, Never>?
    private let homeDirectory = FileManager.default.homeDirectoryForCurrentUser

    var isBusy: Bool { phase != .idle }

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

        let scanner = DiskScanner(homeDirectory: homeDirectory)
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

        activeTask = Task {
            let outcome = await cleaner.clean(items, mode: mode) { [weak self] completed, total in
                Task { @MainActor in
                    guard let self, case .cleaning = self.phase else { return }
                    self.phase = .cleaning(completed: completed, total: total)
                }
            }
            let handledIDs = Set((outcome.removed + outcome.missing).map(\.id))
            report?.items.removeAll { handledIDs.contains($0.id) }
            selectedItemIDs.subtract(handledIDs)
            lastOutcome = outcome
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
            phase = .scanning(status: "Measuring \(completed)/\(total)…")
        }
    }
}

extension CleanupItem {
    /// `Date?` is not `Comparable`, which `KeyPathComparator` requires for table sorting.
    var lastModifiedSortKey: Date { lastModified ?? .distantPast }
}
