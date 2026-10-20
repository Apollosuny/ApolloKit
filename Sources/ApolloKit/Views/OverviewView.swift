import ApolloKitCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarSelection?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if let report = model.report {
                    if model.permissionIssueCount > 0 {
                        fullDiskAccessBanner
                    }
                    if let outcome = model.lastOutcome {
                        CleanupOutcomeView(outcome: outcome)
                    }
                    groupBreakdown(total: report.totalBytes)
                    if !report.issues.isEmpty {
                        issuesSection(report.issues)
                    }
                } else if !model.isBusy {
                    ContentUnavailableView {
                        Label("No scan yet", systemImage: "internaldrive")
                    } description: {
                        Text("Scan caches, Xcode data, package-manager stores and build artifacts in your project folders.")
                    } actions: {
                        Button("Scan Now") { model.startScan() }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .navigationTitle("Overview")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 32) {
            StatView(title: "Reclaimable", value: model.report.map { $0.totalBytes.formatted(.byteCount(style: .file)) } ?? "—")
            StatView(title: "Available on disk", value: Self.availableCapacity.map { $0.formatted(.byteCount(style: .file)) } ?? "—")
            if let report = model.report {
                StatView(title: "Items found", value: report.items.count.formatted())
                StatView(title: "Scan time", value: Duration.seconds(report.finishedAt.timeIntervalSince(report.startedAt))
                    .formatted(.units(allowed: [.minutes, .seconds], width: .narrow)))
            }
        }
    }

    private var fullDiskAccessBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Some locations could not be read")
                    .font(.headline)
                Text("Grant ApolloKit Full Disk Access for a complete scan (Trash, app containers, protected caches).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Settings") { model.openFullDiskAccessSettings() }
        }
        .padding(14)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func groupBreakdown(total: Int64) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("By category").font(.headline)
            ForEach(RuleGroup.allCases) { group in
                let bytes = model.totalBytes(in: group)
                Button {
                    selection = .group(group)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label(group.title, systemImage: group.symbolName)
                            Spacer()
                            Text(bytes.formatted(.byteCount(style: .file)))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: total > 0 ? Double(bytes) / Double(total) : 0)
                            .progressViewStyle(.linear)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func issuesSection(_ issues: [ScanIssue]) -> some View {
        DisclosureGroup("\(issues.count) scan warnings") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(issues.prefix(50)) { issue in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(issue.subject).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                        Text(issue.message).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        }
    }

    private static var availableCapacity: Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

private struct StatView: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title.weight(.semibold)).monospacedDigit()
        }
    }
}

private struct CleanupOutcomeView: View {
    let outcome: CleanupOutcome

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                "Reclaimed \(outcome.reclaimedBytes.formatted(.byteCount(style: .file))) from \(outcome.removed.count) items",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
            .font(.headline)

            if !outcome.failures.isEmpty {
                DisclosureGroup("\(outcome.failures.count) items could not be removed") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(outcome.failures) { failure in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(failure.item.locationDescription).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                                Text(failure.reason).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
