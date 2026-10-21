import ApolloKitCore
import AppKit
import Observation
import ServiceManagement

@MainActor
@Observable
final class StartupItemsModel {
    private(set) var items: [LaunchItem] = []
    private(set) var states = LaunchItemStates()
    private(set) var isLoading = false
    private(set) var busyItemIDs: Set<LaunchItem.ID> = []
    var errorMessage: String?

    @ObservationIgnored private let manager = LaunchItemManager()
    private let homeDirectory = FileManager.default.homeDirectoryForCurrentUser

    var removableOrphans: [LaunchItem] {
        items.filter { $0.isOrphaned && $0.isUserEditable }
    }

    func isEnabled(_ item: LaunchItem) -> Bool {
        !states.disabledLabels.contains(item.label)
    }

    func isRunning(_ item: LaunchItem) -> Bool {
        states.runningLabels.contains(item.label)
    }

    func reload() {
        guard !isLoading else { return }
        isLoading = true
        let manager = manager
        Task {
            items = await Task.detached { manager.items() }.value
            states = await manager.states()
            isLoading = false
        }
    }

    func setEnabled(_ enabled: Bool, for item: LaunchItem) {
        guard item.isUserEditable, !busyItemIDs.contains(item.id) else { return }
        busyItemIDs.insert(item.id)
        let manager = manager
        Task {
            do {
                if enabled {
                    try await manager.enable(item)
                } else {
                    try await manager.disable(item)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            states = await manager.states()
            busyItemIDs.remove(item.id)
        }
    }

    /// Unloads each job, then moves its plist to the Trash so it can be restored.
    func remove(_ itemsToRemove: [LaunchItem]) {
        let editable = itemsToRemove.filter(\.isUserEditable)
        guard !editable.isEmpty else { return }
        busyItemIDs.formUnion(editable.map(\.id))
        let manager = manager
        let cleaner = Cleaner(policy: SafetyPolicy(homeDirectory: homeDirectory))

        Task {
            for item in editable {
                try? await manager.unload(item)
            }
            let cleanupItems = editable.map {
                CleanupItem(url: $0.url, rule: LaunchItemManager.removalRule, sizeInBytes: 0, lastModified: nil, displayName: $0.label)
            }
            let outcome = await cleaner.clean(cleanupItems, mode: .moveToTrash)
            if !outcome.failures.isEmpty {
                errorMessage = outcome.failures.map { "\($0.item.displayName): \($0.reason)" }.joined(separator: "\n")
            }
            busyItemIDs.subtract(editable.map(\.id))
            reload()
        }
    }

    func revealInFinder(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
