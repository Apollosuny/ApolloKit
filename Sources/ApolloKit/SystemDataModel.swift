import ApolloKitCore
import AppKit
import Observation

@MainActor
@Observable
final class SystemDataModel {
    private(set) var entries: [SystemDataEntry] = []
    private(set) var isScanning = false
    private(set) var scannedAt: Date?

    @ObservationIgnored private let scanner = SystemDataScanner()

    var totalBytes: Int64 {
        entries.reduce(0) { $0 + ($1.bytes ?? 0) }
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        let scanner = scanner
        Task {
            // Entries stream in so the fast ones show while the large system folders are still measured.
            var found: [SystemDataEntry] = []
            let stream = AsyncStream<SystemDataEntry> { continuation in
                Task.detached {
                    _ = await scanner.scan { continuation.yield($0) }
                    continuation.finish()
                }
            }
            for await entry in stream {
                found.append(entry)
                entries = found.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
            }
            entries = found.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
            scannedAt = .now
            isScanning = false
        }
    }

    func reveal(_ entry: SystemDataEntry) {
        guard !entry.locations.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(entry.locations)
    }
}
