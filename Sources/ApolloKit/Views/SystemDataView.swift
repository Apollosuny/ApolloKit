import ApolloKitCore
import SwiftUI

/// Breaks down space outside the user's files, which macOS Storage settings shows only as "System Data".
struct SystemDataView: View {
    @Environment(AppModel.self) private var model

    private var systemData: SystemDataModel { model.systemData }

    var body: some View {
        List {
            if !systemData.entries.isEmpty {
                Section {
                    summary
                }
            }
            Section {
                ForEach(systemData.entries) { entry in
                    SystemDataRow(entry: entry, largestBytes: systemData.entries.first?.bytes ?? 0)
                }
            } footer: {
                if !systemData.entries.isEmpty {
                    Text("Sizes marked “at least” include folders macOS doesn't let apps read. Your own files are in Disk Map.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            if systemData.entries.isEmpty {
                if systemData.isScanning {
                    ProgressView("Measuring…")
                } else if systemData.scannedAt != nil {
                    ContentUnavailableView("Nothing found", systemImage: "internaldrive", description: Text("No large system data outside your files."))
                }
            }
        }
        .navigationTitle("System Data")
        .navigationSubtitle(systemData.entries.isEmpty ? "" : "\(systemData.totalBytes.fileSize) outside your files")
        .toolbar {
            ToolbarItem {
                Button("Rescan", systemImage: "arrow.clockwise") { systemData.scan() }
                    .disabled(systemData.isScanning)
            }
        }
        .task {
            if systemData.scannedAt == nil { systemData.scan() }
        }
    }

    private var summary: some View {
        HStack(spacing: 12) {
            Image(systemName: "internaldrive")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(systemData.totalBytes.fileSize) that Finder doesn't show as your files")
                    .font(.headline)
                Text("macOS Storage settings counts most of this as System Data. Simulators and Docker can be cleaned in Smart Scan; the rest is managed by macOS.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct SystemDataRow: View {
    @Environment(AppModel.self) private var model
    let entry: SystemDataEntry
    let largestBytes: Int64

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: entry.symbolName)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.title).font(.headline)
                    if let count = entry.count {
                        Text(entry.kind == .localSnapshots ? "\(count) snapshots" : "\(count) installed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if entry.staleBytes > 0 {
                        Text("\(entry.staleBytes.fileSize) stale")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .foregroundStyle(.orange)
                            .background(.orange.opacity(0.15), in: Capsule())
                    }
                }
                Text(entry.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                remedy
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                Text(sizeText)
                    .font(.headline)
                    .monospacedDigit()
                if let bytes = entry.bytes, largestBytes > 0 {
                    SizeBar(fraction: Double(bytes) / Double(largestBytes), tint: .gray)
                        .frame(width: 90)
                }
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            if !entry.locations.isEmpty {
                Button("Reveal in Finder") { model.systemData.reveal(entry) }
            }
        }
    }

    private var sizeText: String {
        guard let bytes = entry.bytes else { return "Size unknown" }
        return entry.isPartial ? "at least \(bytes.fileSize)" : bytes.fileSize
    }

    @ViewBuilder
    private var remedy: some View {
        switch entry.remedy {
        case .smartScan(let group):
            Button("Review in Smart Scan") { model.reviewInSmartScan(group) }
                .controlSize(.small)
        case .manual(let text):
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .managedByMacOS:
            Label("Managed by macOS", systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
