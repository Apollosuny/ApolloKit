import ApolloKitCore
import Observation

@MainActor
@Observable
final class HistoryModel {
    private(set) var history: CleanupHistory

    @ObservationIgnored private let store = CleanupHistoryStore()

    init() {
        history = store.load()
    }

    func record(_ record: CleanupRecord) {
        history.append(record)
        save()
    }

    func record(_ snapshot: ScanSnapshot) {
        history.append(snapshot)
        save()
    }

    func clear() {
        history = CleanupHistory()
        save()
    }

    /// The file is a few hundred kilobytes at most, so it is written synchronously to keep saves ordered.
    private func save() {
        try? store.save(history)
    }
}
