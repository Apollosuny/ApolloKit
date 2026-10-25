import ApolloKitCore
import SwiftUI

/// The Smart Scan screen: a single place that walks through
/// start → scanning → results → cleaning → completion.
struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarSelection?

    var body: some View {
        Group {
            switch model.phase {
            case .scanning(let status):
                ScanningView(status: status)
            case .cleaning(let completed, let total):
                CleaningView(completed: completed, total: total)
            case .idle:
                if model.showsCompletion, let outcome = model.lastOutcome {
                    CompletionView(outcome: outcome)
                } else if model.report != nil {
                    ResultsView(selection: $selection)
                } else {
                    ScanStartView()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.smooth(duration: 0.35), value: screenKey)
        .navigationTitle("Smart Scan")
    }

    private var screenKey: String {
        switch model.phase {
        case .scanning: "scanning"
        case .cleaning: "cleaning"
        case .idle: model.showsCompletion ? "done" : (model.report == nil ? "start" : "results")
        }
    }
}

// MARK: - Start

private struct ScanStartView: View {
    @Environment(AppModel.self) private var model
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Button {
                model.startScan()
            } label: {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [.brandOrangeLight, .brandOrange], startPoint: .top, endPoint: .bottom))
                        .overlay {
                            Circle()
                                .strokeBorder(
                                    LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center),
                                    lineWidth: 1.5
                                )
                        }
                        .shadow(color: .brandOrange.opacity(isHovering ? 0.45 : 0.25), radius: isHovering ? 28 : 18, y: 8)
                    VStack(spacing: 6) {
                        Image(systemName: "sparkle.magnifyingglass")
                            .font(.system(size: 44, weight: .semibold))
                        Text("Scan")
                            .font(.title2.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                }
                .frame(width: 180, height: 180)
                .scaleEffect(isHovering ? 1.04 : 1)
                .animation(.spring(duration: 0.3), value: isHovering)
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("Start scan")

            VStack(spacing: 6) {
                Text("Find what your Mac can let go of")
                    .font(.title2.weight(.semibold))
                Text("Caches, Xcode and simulator data, package stores, toolchains, Docker, project build artifacts and large forgotten files.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 460)

            if let disk = model.diskSpace {
                StorageBar(
                    segments: [
                        .init(id: "used", title: "Used", bytes: disk.usedBytes, color: .secondary),
                        .init(id: "free", title: "Available", bytes: disk.availableBytes, color: .green.opacity(0.35)),
                    ],
                    totalBytes: disk.totalBytes
                )
                .frame(maxWidth: 460)
            }

            HStack(spacing: 18) {
                Label("\(model.preferences.enabledRuleIDs.count) rules", systemImage: "checklist")
                Label("\(model.preferences.projectRoots.count) project folders", systemImage: "folder")
                SettingsLink {
                    Text("Customize…")
                }
                .buttonStyle(.link)
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(32)
    }
}

// MARK: - Scanning

private struct ScanningView: View {
    @Environment(AppModel.self) private var model
    let status: String

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            ProgressRing(fraction: model.scanFraction, tint: .brandOrange) {
                VStack(spacing: 2) {
                    Text(model.liveTotalBytes.fileSize)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy, value: model.liveTotalBytes)
                    Text("found so far")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 200, height: 200)

            Text(status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 520)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
                ForEach(RuleGroup.allCases) { group in
                    let bytes = model.liveBytesByGroup[group] ?? 0
                    HStack(spacing: 10) {
                        GroupIcon(group: group, size: 24)
                        Text(group.title)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(bytes > 0 ? bytes.fileSize : "—")
                            .monospacedDigit()
                            .foregroundStyle(bytes > 0 ? .primary : .tertiary)
                            .contentTransition(.numericText())
                            .animation(.snappy, value: bytes)
                    }
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .cardSurface()
                }
            }
            .frame(maxWidth: 640)

            Button("Stop Scan", role: .cancel) { model.cancel() }
                .secondaryActionStyle()
                .controlSize(.large)

            Spacer()
        }
        .padding(32)
    }
}

// MARK: - Results

private struct ResultsView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarSelection?

    var body: some View {
        let report = model.report
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header(report)

                if let disk = model.diskSpace {
                    storageSummary(disk: disk, reclaimable: report?.totalBytes ?? 0)
                }

                if model.permissionIssueCount > 0 {
                    FullDiskAccessBanner()
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 14)], spacing: 14) {
                    ForEach(model.groupsWithFindings) { group in
                        CategoryCard(group: group) { selection = .group(group) }
                    }
                }

                let emptyGroups = RuleGroup.allCases.filter { model.totalBytes(in: $0) == 0 }
                if !emptyGroups.isEmpty {
                    Text("Nothing to clean in \(emptyGroups.map(\.title).formatted(.list(type: .and))).")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }

                if let issues = report?.issues, !issues.isEmpty {
                    IssuesSection(issues: issues)
                }
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func header(_ report: ScanReport?) -> some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Scan complete")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text((report?.totalBytes ?? 0).fileSize)
                        .font(.system(size: 46, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("can be freed")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                if let report {
                    let duration = Duration.seconds(report.finishedAt.timeIntervalSince(report.startedAt))
                    Text("\(report.items.count) items · scanned \(report.finishedAt, format: .relative(presentation: .named)) in \(duration.formatted(.units(allowed: [.minutes, .seconds], width: .narrow)))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Scan Again", systemImage: "arrow.clockwise") { model.startScan() }
                .secondaryActionStyle()
        }
    }

    private func storageSummary(disk: DiskSpace, reclaimable: Int64) -> some View {
        let selected = model.selectedBytes
        return VStack(alignment: .leading, spacing: 10) {
            Text("Macintosh HD · \(disk.availableBytes.fileSize) available of \(disk.totalBytes.fileSize)")
                .font(.subheadline.weight(.medium))
            StorageBar(
                segments: [
                    .init(id: "selected", title: "Selected", bytes: selected, color: .accentColor),
                    .init(id: "reclaimable", title: "Other reclaimable", bytes: max(0, reclaimable - selected), color: .accentColor.opacity(0.35)),
                    .init(id: "other", title: "Other data", bytes: max(0, disk.usedBytes - reclaimable), color: .secondary),
                    .init(id: "free", title: "Available", bytes: disk.availableBytes, color: .green.opacity(0.35)),
                ],
                totalBytes: disk.totalBytes
            )
        }
        .padding(16)
        .cardSurface()
    }
}

private struct CategoryCard: View {
    @Environment(AppModel.self) private var model
    let group: RuleGroup
    let open: () -> Void

    @State private var isHovering = false

    var body: some View {
        let items = model.items(in: group)
        let total = model.totalBytes(in: group)
        let selected = model.selectedBytes(in: group)
        let cautionCount = items.filter { $0.risk == .caution }.count

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                GroupIcon(group: group, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.title).font(.headline).lineLimit(1)
                    Text("\(items.count) items" + (cautionCount > 0 ? " · \(cautionCount) caution" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button {
                    toggleSelection(items)
                } label: {
                    Image(systemName: selectionSymbol(selected: selected, total: total))
                        .font(.title3)
                        .foregroundStyle(selected > 0 ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(selected > 0 ? "Deselect all in \(group.title)" : "Select safe items in \(group.title)")
                .accessibilityLabel(selected > 0 ? "Deselect \(group.title)" : "Select safe items in \(group.title)")
            }

            Text(total.fileSize)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()

            VStack(alignment: .leading, spacing: 5) {
                ProgressView(value: total > 0 ? Double(selected) / Double(total) : 0)
                    .tint(group.tint)
                Text(selected > 0 ? "\(selected.fileSize) selected" : "Nothing selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(16)
        .cardSurface(highlighted: isHovering)
        .scaleEffect(isHovering ? 1.01 : 1)
        .animation(.snappy(duration: 0.2), value: isHovering)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onHover { isHovering = $0 }
        .onTapGesture(perform: open)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Review \(group.title)", open)
        .accessibilityAddTraits(.isButton)
    }

    private func selectionSymbol(selected: Int64, total: Int64) -> String {
        if selected == 0 { return "circle" }
        return selected >= total ? "checkmark.circle.fill" : "minus.circle.fill"
    }

    private func toggleSelection(_ items: [CleanupItem]) {
        if model.selectedBytes(in: group) > 0 {
            model.select(items, false)
        } else {
            model.select(items.filter { $0.risk == .safe }, true)
        }
    }
}

// MARK: - Cleaning & completion

private struct CleaningView: View {
    @Environment(AppModel.self) private var model
    let completed: Int
    let total: Int

    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            ProgressRing(fraction: total > 0 ? Double(completed) / Double(total) : 0, tint: .green) {
                VStack(spacing: 2) {
                    Text("\(completed) / \(total)")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy, value: completed)
                    Text("items cleaned")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 200, height: 200)

            VStack(spacing: 4) {
                Text("Cleaning up…").font(.title2.weight(.semibold))
                if let name = model.cleaningItemName {
                    Text(name)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 480)
                }
            }

            Button("Stop After Current Item", role: .cancel) { model.cancel() }
                .secondaryActionStyle()
                .controlSize(.large)
            Spacer()
        }
        .padding(32)
    }
}

private struct CompletionView: View {
    @Environment(AppModel.self) private var model
    let outcome: CleanupOutcome

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: outcome.failures.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 76))
                .foregroundStyle(outcome.failures.isEmpty ? Color.green.gradient : Color.orange.gradient)
                .symbolEffect(.bounce, value: outcome.removed.count)

            VStack(spacing: 6) {
                Text("\(outcome.reclaimedBytes.fileSize) freed")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("\(outcome.removed.count) items removed" + (outcome.failures.isEmpty ? "" : " · \(outcome.failures.count) failed"))
                    .foregroundStyle(.secondary)
                if let disk = model.diskSpace {
                    Text("\(disk.availableBytes.fileSize) now available")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if !outcome.failures.isEmpty {
                FailuresList(failures: outcome.failures)
                    .frame(maxWidth: 560)
            }

            HStack(spacing: 12) {
                Button("Review Remaining") { model.showsCompletion = false }
                    .secondaryActionStyle()
                Button("Scan Again") { model.startScan() }
                    .prominentActionStyle()
            }
            .controlSize(.large)
            Spacer()
        }
        .padding(32)
    }
}

// MARK: - Shared sections

private struct FullDiskAccessBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Some locations could not be read").font(.headline)
                Text("Grant ApolloKit Full Disk Access for a complete scan (Trash, backups, protected caches).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Settings") { model.openFullDiskAccessSettings() }
        }
        .padding(14)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct IssuesSection: View {
    let issues: [ScanIssue]

    var body: some View {
        DisclosureGroup("\(issues.count) scan warnings") {
            VStack(alignment: .leading, spacing: 6) {
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
        .foregroundStyle(.secondary)
    }
}

private struct FailuresList: View {
    let failures: [CleanupFailure]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(failures) { failure in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(failure.item.displayName).font(.callout.weight(.medium))
                        Text(failure.reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .frame(maxHeight: 160)
        .cardSurface()
    }
}
