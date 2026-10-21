import ApolloKitCore
import AppKit
import SwiftUI

/// Status item: a disk gauge plus free space, or progress while a scan or cleanup runs.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbolName)
            if let text {
                Text(text).monospacedDigit()
            }
        }
    }

    private var symbolName: String {
        switch model.phase {
        case .scanning: return "sparkle.magnifyingglass"
        case .cleaning: return "sparkles"
        case .idle:
            guard let disk = model.diskSpace else { return "internaldrive" }
            if disk.isLow { return "exclamationmark.triangle.fill" }
            switch disk.usedFraction {
            case ..<0.2: return "gauge.with.dots.needle.0percent"
            case ..<0.42: return "gauge.with.dots.needle.33percent"
            case ..<0.58: return "gauge.with.dots.needle.50percent"
            case ..<0.85: return "gauge.with.dots.needle.67percent"
            default: return "gauge.with.dots.needle.100percent"
            }
        }
    }

    private var text: String? {
        switch model.phase {
        case .scanning:
            return model.scanFraction.map { "\(Int($0 * 100))%" } ?? "Scanning"
        case .cleaning(let completed, let total):
            return "\(completed)/\(total)"
        case .idle:
            guard model.preferences.showsFreeSpaceInMenuBar, let disk = model.diskSpace else { return nil }
            return disk.availableBytes.fileSize
        }
    }
}

/// Compact popover: disk, latest findings, two actions. Deletion always goes through the main window's review.
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private let topGroupCount = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let disk = model.diskSpace {
                diskSection(disk)
            }
            Divider()
            findingsSection
            actions
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 290)
        .onAppear { model.refreshDiskSpace() }
    }

    private func diskSection(_ disk: DiskSpace) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(disk.availableBytes.fileSize) free")
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(disk.isLow ? Color.orange : .primary)
                Spacer()
                Text("of \(disk.totalBytes.fileSize)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: disk.usedFraction)
                .tint(disk.isLow ? .orange : .accentColor)
        }
    }

    @ViewBuilder
    private var findingsSection: some View {
        switch model.phase {
        case .scanning(let status):
            VStack(alignment: .leading, spacing: 6) {
                Text("\(model.liveTotalBytes.fileSize) found so far")
                    .font(.headline)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy, value: model.liveTotalBytes)
                if let fraction = model.scanFraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        case .cleaning(let completed, let total):
            VStack(alignment: .leading, spacing: 6) {
                Text("Cleaning \(completed) of \(total)…").font(.headline)
                ProgressView(value: Double(completed), total: Double(max(total, 1)))
                if let name = model.cleaningItemName {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        case .idle:
            if let report = model.report {
                reportSummary(report)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Not scanned yet").font(.headline)
                    Text("Scan to find caches and build artifacts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func reportSummary(_ report: ScanReport) -> some View {
        let groups = model.groupsWithFindings
        let otherBytes = groups.dropFirst(topGroupCount).reduce(0) { $0 + model.totalBytes(in: $1) }

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(report.totalBytes.fileSize)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                Text("reclaimable")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 5) {
                ForEach(groups.prefix(topGroupCount)) { group in
                    summaryRow(title: group.title, bytes: model.totalBytes(in: group)) {
                        GroupIcon(group: group, size: 16)
                    }
                }
                if otherBytes > 0 {
                    summaryRow(title: "Other", bytes: otherBytes) {
                        Image(systemName: "ellipsis.circle.fill")
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                    }
                }
            }

            TimelineView(.everyMinute) { _ in
                Group {
                    if model.showsCompletion, let outcome = model.lastOutcome {
                        Text("Freed \(outcome.reclaimedBytes.fileSize) · scanned \(report.finishedAt, format: .relative(presentation: .named))")
                    } else {
                        Text("Scanned \(report.finishedAt, format: .relative(presentation: .named))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func summaryRow<Icon: View>(title: String, bytes: Int64, @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: 8) {
            icon()
            Text(title).lineLimit(1)
            Spacer()
            Text(bytes.fileSize)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if model.isBusy {
                Button { model.cancel() } label: {
                    Text("Stop").frame(maxWidth: .infinity)
                }
                .secondaryActionStyle()
            } else if model.report == nil {
                // Before the first scan there is nothing to review, so Scan is the only action.
                Button { model.startScan() } label: {
                    Text("Scan").frame(maxWidth: .infinity)
                }
                .prominentActionStyle()
            } else {
                Button { model.startScan() } label: {
                    Text("Scan Again").frame(maxWidth: .infinity)
                }
                .secondaryActionStyle()

                Button { showMainWindow() } label: {
                    Text("Review & Clean").frame(maxWidth: .infinity)
                }
                .prominentActionStyle()
                .disabled(model.report?.items.isEmpty ?? true)
            }
        }
        .controlSize(.large)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Open ApolloKit") { showMainWindow() }
            Spacer()
            Button {
                AppActivation.bringToFront()
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit ApolloKit")
            .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .font(.callout)
    }

    private func showMainWindow() {
        AppActivation.bringToFront()
        openWindow(id: ApolloKitApp.mainWindowID)
    }
}
