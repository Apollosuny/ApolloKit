import ApolloKitCore
import AppKit
import Charts
import SwiftUI

struct HistoryView: View {
    private struct WeeklyBar: Identifiable {
        let week: Date
        let group: RuleGroup
        let gigabytes: Double
        var id: String { "\(week.timeIntervalSince1970)-\(group.rawValue)" }
    }

    @Environment(AppModel.self) private var model
    @State private var isConfirmingClear = false

    private var history: CleanupHistory { model.history.history }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                summaryTiles

                if history.records.isEmpty {
                    ContentUnavailableView(
                        "No cleanups yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Space freed by Smart Scan and the Uninstaller is recorded here.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                } else {
                    weeklyChart
                }
                growthSection
                if !history.records.isEmpty {
                    recentCleanups
                }
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("History")
        .toolbar {
            ToolbarItem {
                Button("Clear History", systemImage: "trash") { isConfirmingClear = true }
                    .disabled(history.records.isEmpty && history.snapshots.isEmpty)
            }
        }
        .confirmationDialog("Clear cleanup history?", isPresented: $isConfirmingClear) {
            Button("Clear History", role: .destructive) { model.history.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only the history is removed. Nothing on disk changes.")
        }
    }

    // MARK: - Sections

    private var summaryTiles: some View {
        let monthAgo = Date.now.addingTimeInterval(-30 * 24 * 60 * 60)
        return HStack(spacing: 14) {
            tile("Freed in total", history.totalReclaimedBytes.fileSize)
            tile("Last 30 days", history.reclaimedBytes(since: monthAgo).fileSize)
            tile("Cleanups", history.records.count.formatted())
        }
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardSurface()
    }

    private var weeklyChart: some View {
        let bars = weeklyBars
        let groups = RuleGroup.allCases.filter { group in bars.contains { $0.group == group } }

        return VStack(alignment: .leading, spacing: 12) {
            Text("Freed per week").font(.headline)
            Chart(bars) { bar in
                BarMark(
                    x: .value("Week", bar.week, unit: .weekOfYear),
                    y: .value("Freed (GB)", bar.gigabytes)
                )
                .foregroundStyle(by: .value("Category", bar.group.title))
            }
            .chartForegroundStyleScale(domain: groups.map(\.title), range: groups.map(\.tint))
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let gigabytes = value.as(Double.self) {
                            Text("\(gigabytes.formatted(.number.precision(.fractionLength(0...1)))) GB")
                        }
                    }
                }
            }
            .frame(height: 220)
        }
        .padding(16)
        .cardSurface()
    }

    @ViewBuilder
    private var growthSection: some View {
        let day: TimeInterval = 24 * 60 * 60
        let weekly = history.growth(over: 7 * day)
        let growth = weekly.isEmpty ? history.growth(over: day) : weekly

        VStack(alignment: .leading, spacing: 10) {
            if let since = growth.first?.since {
                Text("Growing fastest since \(since.formatted(date: .abbreviated, time: .omitted))").font(.headline)
                ForEach(growth.prefix(5), id: \.group) { entry in
                    HStack(spacing: 10) {
                        GroupIcon(group: entry.group, size: 22)
                        Text(entry.group.title)
                        Spacer()
                        Label("+\(entry.bytes.fileSize)", systemImage: "arrow.up.right")
                            .monospacedDigit()
                            .foregroundStyle(.orange)
                    }
                }
            } else {
                Text("Growing fastest").font(.headline)
                Text("Scan again over the next few days to see which caches grow fastest.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func symbol(for source: CleanupRecord.Source) -> String {
        switch source {
        case .smartScan: "sparkle.magnifyingglass"
        case .uninstaller: "trash.square"
        case .diskMap: "chart.pie"
        }
    }

    private func title(for record: CleanupRecord) -> String {
        switch record.source {
        case .smartScan: "Smart Scan cleanup"
        case .uninstaller: record.title.map { "Uninstalled \($0)" } ?? "Uninstall"
        case .diskMap: "Disk Map cleanup"
        }
    }

    private var recentCleanups: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent cleanups").font(.headline)
            ForEach(history.records.reversed().prefix(20)) { record in
                HStack(spacing: 10) {
                    Image(systemName: symbol(for: record.source))
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title(for: record))
                        Text("\(record.date.formatted(date: .abbreviated, time: .shortened)) · \(record.itemCount) items")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let locations = record.locations, !locations.isEmpty {
                        RecordLocationsButton(locations: locations, itemCount: record.itemCount)
                    }
                    if record.movedToTrash {
                        Text("Trash")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .foregroundStyle(.secondary)
                            .background(Color.secondary.opacity(0.14), in: Capsule())
                            .help("Moved to the Trash; the space is freed once the Trash is emptied.")
                    }
                    Text(record.reclaimedBytes.fileSize)
                        .monospacedDigit()
                        .frame(minWidth: 80, alignment: .trailing)
                }
                if record.id != history.records.first?.id {
                    Divider()
                }
            }
        }
        .padding(16)
        .cardSurface()
    }

    /// The last 12 weeks, one bar segment per group.
    private var weeklyBars: [WeeklyBar] {
        let calendar = Calendar.current
        guard let cutoff = calendar.date(byAdding: .weekOfYear, value: -12, to: .now) else { return [] }
        var totals: [Date: [RuleGroup: Int64]] = [:]
        for record in history.records where record.date >= cutoff {
            guard let week = calendar.dateInterval(of: .weekOfYear, for: record.date)?.start else { continue }
            for (rawGroup, bytes) in record.bytesByGroup {
                guard let group = RuleGroup(rawValue: rawGroup) else { continue }
                totals[week, default: [:]][group, default: 0] += bytes
            }
        }
        return totals.flatMap { week, groups in
            groups.map { WeeklyBar(week: week, group: $0.key, gigabytes: Double($0.value) / 1_000_000_000) }
        }
        .sorted { $0.week < $1.week }
    }
}

/// Lists what a cleanup removed, so a tool that stopped working afterwards can be traced back.
private struct RecordLocationsButton: View {
    let locations: [String]
    let itemCount: Int
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "list.bullet")
        }
        .buttonStyle(.borderless)
        .help("Show removed items")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Removed items").font(.headline)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(locations.joined(separator: "\n"), forType: .string)
                    }
                }
                ScrollView {
                    Text(locations.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if itemCount > locations.count {
                    Text("Largest \(locations.count) of \(itemCount) items.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(width: 520, height: 320)
        }
    }
}
