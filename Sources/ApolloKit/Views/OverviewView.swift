import ApolloKitCore
import AppKit
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
            case .cleaning:
                if let cleaning = model.cleaning {
                    CleaningView(cleaning: cleaning)
                }
            case .idle:
                if model.showsCompletion, let outcome = model.lastOutcome {
                    CompletionView(outcome: outcome, selection: $selection)
                } else if model.report != nil {
                    ResultsView(selection: $selection)
                } else {
                    ScanStartView(selection: $selection)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.smooth(duration: 0.4), value: screenKey)
        .navigationTitle("Smart Scan")
        .navigationSubtitle(subtitle)
    }

    private var screenKey: String {
        switch model.phase {
        case .scanning: "scanning"
        case .cleaning: "cleaning"
        case .idle: model.showsCompletion ? "done" : (model.report == nil ? "start" : "results")
        }
    }

    private var subtitle: String {
        switch model.phase {
        case .scanning: return "Scanning…"
        case .cleaning(let completed, let total): return "Cleaning \(min(completed + 1, total)) of \(total)"
        case .idle:
            if model.showsCompletion { return "Cleanup complete" }
            guard let report = model.report else { return "Not scanned yet" }
            return "\(report.totalBytes.fileSize) found in \(RuleGroup.allCases.filter { model.totalBytes(in: $0) > 0 }.count) categories"
        }
    }
}

// MARK: - Start

private struct ScanStartView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarSelection?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let disk = model.diskSpace {
                    diskSummary(disk)
                }

                Button {
                    model.startScan()
                } label: {
                    Text("Scan")
                        .font(.system(size: 17, weight: .semibold))
                        .padding(.horizontal, 30)
                        .frame(minHeight: 30)
                }
                .prominentActionStyle()
                .buttonBorderShape(.capsule)
                .controlSize(.extraLarge)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 30)

                Text(scanCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)

                scanScope
                    .frame(maxWidth: 760)
                    .padding(.top, 34)

                if let last = lastCleanup {
                    HStack(spacing: 10) {
                        Text(lastCleanupText(last))
                        Button("Show History") { selection = .history }
                            .buttonStyle(.link)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 16)
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 34)
            .frame(maxWidth: .infinity)
        }
    }

    private func diskSummary(_ disk: DiskSpace) -> some View {
        VStack(spacing: 0) {
            Text("Macintosh HD")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(disk.availableBytes.fileSize) available")
                .font(.system(size: 58, weight: .semibold))
                .monospacedDigit()
                .padding(.top, 6)
            Text("of \(disk.totalBytes.fileSize)")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            VStack(spacing: 10) {
                DiskUsageBar(
                    segments: [
                        .init(id: "used", bytes: disk.usedBytes, color: .usedSpace),
                        .init(id: "available", bytes: disk.availableBytes, color: .clear),
                    ],
                    height: 14
                )
                HStack(spacing: 16) {
                    LegendDot(color: .usedSpace, title: "Used \(disk.usedBytes.fileSize)")
                    LegendDot(color: .availableSpace, title: "Available \(disk.availableBytes.fileSize)")
                }
            }
            .frame(maxWidth: 660)
            .padding(.top, 24)
        }
        .accessibilityElement(children: .combine)
    }

    private var scanCaption: String {
        let ruleCount = model.preferences.enabledRuleIDs.count
        let folderCount = model.preferences.projectRoots.count
        let folders = folderCount == 1 ? "1 project folder" : "\(folderCount) project folders"
        return "Checks \(ruleCount) rules and \(folders) · ⌘R"
    }

    private var scanScope: some View {
        let enabled = model.preferences.enabledRuleIDs
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Smart Scan looks in")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                SettingsLink {
                    Text("Edit Rules…")
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .leading), count: 3), spacing: 10) {
                ForEach(RuleGroup.allCases) { group in
                    let isOn = RuleCatalog.all.contains { $0.group == group && enabled.contains($0.id) }
                    HStack(spacing: 9) {
                        GroupIcon(group: group, size: 24)
                        Text(group.title)
                            .font(.system(size: 12.5))
                            .lineLimit(1)
                    }
                    .opacity(isOn ? 1 : 0.4)
                    .help(isOn ? group.title : "\(group.title) is turned off in Settings")
                }
            }
        }
        .groupedBox(padding: 16)
    }

    private var lastCleanup: CleanupRecord? {
        model.history.history.records.last { $0.source == .smartScan }
    }

    private func lastCleanupText(_ record: CleanupRecord) -> String {
        let when = record.date.formatted(.relative(presentation: .named))
        let how = record.movedToTrash ? "It went to the Trash." : "It was deleted permanently."
        return "Last cleanup \(when) freed \(record.reclaimedBytes.fileSize). \(how)"
    }
}

// MARK: - Scanning

private struct ScanningView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let status: ScanStatus

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                TimelineView(.animation(minimumInterval: 0.125, paused: reduceMotion)) { context in
                    ProgressRing(fraction: model.scanEstimate.displayed(at: context.date)) {
                        VStack(spacing: 2) {
                            Text(model.liveTotalBytes.fileSize)
                                .font(.system(size: 34, weight: .semibold))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .animation(.snappy, value: model.liveTotalBytes)
                            Text("found so far")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 196, height: 196)

                TimelineView(.periodic(from: status.stageStartedAt, by: 1)) { context in
                    let copy = stageCopy(at: context.date)
                    VStack(spacing: 0) {
                        Text(copy.title)
                            .font(.system(size: 22, weight: .semibold))
                            .padding(.top, 24)
                        Text(copy.detail)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 540)
                            .padding(.top, 6)
                        Text(status.currentItem ?? " ")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 620)
                            .padding(.top, 10)

                        categoryGrid(at: context.date)
                            .frame(maxWidth: 760)
                            .padding(.top, 24)
                    }
                }

                Button("Stop") { model.cancel() }
                    .capsuleButtonStyle()
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                    .padding(.top, 22)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity)
        }
    }

    private func stageCopy(at date: Date) -> (title: String, detail: String) {
        switch status.stage {
        case .locating:
            return ("Looking for caches and projects…", "Checking \(model.preferences.enabledRuleIDs.count) rules and walking your project folders.")
        case .measuring:
            return ("Measuring folders…", "Sizing caches, simulators and toolchains · \(status.completed) of \(status.total) folders.")
        case .finishing(.checkingProjects):
            return ("Checking which projects are active…", "Reading file dates and Git activity, so recent work is never selected.")
        case .finishing(.checkingFilesInUse):
            return ("Checking files in use…", "Asking macOS which apps have files open, so nothing in use is selected.")
        case .finishing(.waitingForTools):
            let seconds = Int(date.timeIntervalSince(status.stageStartedAt))
            if seconds < 2 { return ("Summing up…", "Adding up what was found.") }
            return ("Waiting for Docker and Xcode…", "They report image and simulator sizes through their own tools. This can take up to 20 seconds.")
        }
    }

    private func categoryGrid(at date: Date) -> some View {
        let enabled = model.preferences.enabledRuleIDs
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .leading), count: 3), spacing: 12) {
            ForEach(RuleGroup.allCases) { group in
                let isOn = RuleCatalog.all.contains { $0.group == group && enabled.contains($0.id) }
                let state = categoryState(group, isOn: isOn, at: date)
                HStack(spacing: 10) {
                    GroupIcon(group: group, size: 24)
                        .opacity(state.isQueued ? 0.4 : 1)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.title)
                            .font(.system(size: 12.5))
                            .lineLimit(1)
                        Text(state.text)
                            .font(.system(size: 11.5))
                            .monospacedDigit()
                            .foregroundStyle(state.isActive ? AnyShapeStyle(Color.accentText) : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                            .contentTransition(.numericText())
                    }
                }
                .frame(height: 36)
                .accessibilityElement(children: .combine)
            }
        }
        .groupedBox(padding: 16)
        .animation(.snappy, value: model.liveBytesByGroup)
    }

    private struct CategoryState {
        var text: String
        var isActive = false
        var isQueued = false
    }

    private func categoryState(_ group: RuleGroup, isOn: Bool, at date: Date) -> CategoryState {
        guard isOn else { return CategoryState(text: "Off", isQueued: true) }
        let bytes = model.liveBytesByGroup[group] ?? 0
        switch status.stage {
        case .locating:
            return CategoryState(text: "Queued", isQueued: true)
        case .measuring:
            return bytes > 0
                ? CategoryState(text: "Measuring… \(bytes.fileSize)", isActive: true)
                : CategoryState(text: "Queued", isQueued: true)
        case .finishing(let step):
            if group == .projectArtifacts, step == .checkingProjects {
                return CategoryState(text: "Checking projects… \(bytes.fileSize)", isActive: true)
            }
            if group == .docker || group == .xcode, step == .waitingForTools {
                let seconds = Int(date.timeIntervalSince(status.stageStartedAt))
                let tool = group == .docker ? "Docker" : "simulators"
                return CategoryState(text: "Waiting for \(tool) · \(seconds) s", isActive: true)
            }
            return CategoryState(text: bytes > 0 ? "✓ \(bytes.fileSize)" : "Nothing found")
        }
    }
}

// MARK: - Results

private struct ResultsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selection: SidebarSelection?
    @State private var hasAppeared = false
    @State private var showsIssues = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                categoryList

                notices
            }
            .padding(.horizontal, 36)
            .padding(.top, 22)
            .padding(.bottom, 96)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { hasAppeared = true }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 32) {
            VStack(alignment: .leading, spacing: 6) {
                if let report = model.report {
                    TimelineView(.everyMinute) { _ in
                        Text("Scan complete · \(report.finishedAt, format: .relative(presentation: .named))")
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 14) { headline; headlineCaption }
                    VStack(alignment: .leading, spacing: 4) { headline; headlineCaption }
                }
                Text(foundSummary)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let disk = model.diskSpace {
                afterCleanup(disk)
                    .frame(width: 300)
                    .padding(.bottom, 4)
            }
        }
    }

    private var headline: some View {
        Text(model.safeBytes.fileSize)
            .font(.system(size: 60, weight: .semibold))
            .monospacedDigit()
            .contentTransition(.numericText())
    }

    private var headlineCaption: some View {
        Text("can be freed safely.")
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private var foundSummary: String {
        guard let report = model.report else { return "" }
        let found = "Found \(report.totalBytes.fileSize) in \(report.items.count) items."
        let caution = model.cautionBytes
        return caution > 0 ? "\(found) \(caution.fileSize) needs your review, so it isn't selected." : found
    }

    private func afterCleanup(_ disk: DiskSpace) -> some View {
        let selected = min(model.selectedBytes, disk.usedBytes)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("After cleanup").foregroundStyle(.secondary)
                Spacer()
                Text("\(disk.availableBytes.fileSize) → ").foregroundStyle(.secondary)
                    + Text("\((disk.availableBytes + selected).fileSize) available").fontWeight(.semibold)
            }
            .font(.caption)
            .monospacedDigit()
            DiskUsageBar(
                segments: [
                    .init(id: "used", bytes: disk.usedBytes - selected, color: .usedSpace),
                    .init(id: "selected", bytes: selected, color: .accentColor),
                    .init(id: "available", bytes: disk.availableBytes, color: .clear),
                ],
                height: 8
            )
            .animation(.snappy, value: selected)
        }
        .accessibilityElement(children: .combine)
    }

    private var categoryList: some View {
        let largest = RuleGroup.allCases.map { model.totalBytes(in: $0) }.max() ?? 0
        return VStack(spacing: 0) {
            ForEach(Array(RuleGroup.allCases.enumerated()), id: \.element) { index, group in
                if index > 0 {
                    Divider().padding(.leading, 56)
                }
                ResultRow(group: group, largestBytes: largest) { selection = .group(group) }
                    .opacity(hasAppeared || reduceMotion ? 1 : 0)
                    .offset(y: hasAppeared || reduceMotion ? 0 : 6)
                    .animation(.smooth(duration: 0.35).delay(Double(index) * 0.025), value: hasAppeared)
            }
        }
        .padding(.vertical, 4)
        .groupedBox()
    }

    @ViewBuilder
    private var notices: some View {
        if model.permissionIssueCount > 0 {
            Notice(
                kind: .info,
                title: "\(model.permissionIssueCount) folders could not be read.",
                message: "Grant Full Disk Access for complete sizes. ApolloKit only reads sizes and dates."
            ) {
                Button("Open Privacy Settings…") { model.openFullDiskAccessSettings() }
            }
        }
        let otherIssues = model.report?.issues.filter { !$0.isPermissionDenied } ?? []
        if !otherIssues.isEmpty {
            Notice(
                kind: .warning,
                title: "\(otherIssues.count) locations could not be measured.",
                message: "Their sizes are left out of the results."
            ) {
                Button(showsIssues ? "Hide Items" : "Show Items") { showsIssues.toggle() }
                Button("Retry") { model.startScan() }
            }
            if showsIssues {
                IssuesList(issues: otherIssues)
            }
        }
    }
}

/// One category in the results: selection, size against the largest category, and what needs a decision.
private struct ResultRow: View {
    @Environment(AppModel.self) private var model
    let group: RuleGroup
    let largestBytes: Int64
    let open: () -> Void
    @State private var isHovering = false

    var body: some View {
        let items = model.items(in: group)
        let total = model.totalBytes(in: group)
        let selected = model.selectedBytes(in: group)
        let cautionCount = items.filter { $0.risk == .caution }.count

        HStack(spacing: 14) {
            SelectionCheckbox(state: .init(selected: selected, total: total)) { toggleSelection(items) }
                .disabled(items.isEmpty)
                .help(selected > 0 ? "Deselect all in \(group.title)" : "Select safe items in \(group.title)")

            HStack(spacing: 10) {
                GroupIcon(group: group, size: 24)
                Text(group.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .layoutPriority(1)
                if let note = note(for: items) {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                if cautionCount > 0 {
                    CautionGlyph()
                    Text("\(cautionCount) to review")
                } else if items.isEmpty {
                    Text("Nothing to clean")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 130, alignment: .leading)

            SizeShareBar(tint: group.tint, total: total, selected: selected, largest: largestBytes)
                .frame(width: 120)
                .opacity(total > 0 ? 1 : 0)

            Group {
                if total > 0 {
                    Text(selected.fileSize)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selected > 0 ? .primary : .secondary)
                        + Text(" of \(total.fileSize)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .monospacedDigit()
            .lineLimit(1)
            .frame(width: 120, alignment: .trailing)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .frame(height: 40)
        .padding(.horizontal, 16)
        .background(isHovering ? Color.primary.opacity(0.04) : .clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: open)
        .animation(.snappy, value: selected)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Review \(group.title)", open)
        .accessibilityAddTraits(.isButton)
    }

    /// The one fact that explains a category's number, such as why some of it is not selected.
    private func note(for items: [CleanupItem]) -> String? {
        guard !items.isEmpty else { return nil }
        switch group {
        case .projectArtifacts:
            let active = items.filter { $0.concerns.contains { if case .activeProject = $0 { true } else { false } } }.count
            return active > 0 ? "\(active) active or recent" : nil
        case .apps:
            guard let leftover = items.filter({ $0.rule.id == "apps.leftovers" }).max(by: { $0.sizeInBytes < $1.sizeInBytes }) else { return nil }
            let name = leftover.displayName.components(separatedBy: " › ").last ?? leftover.displayName
            return "\(name) \(leftover.sizeInBytes.fileSize) · app not installed"
        case .toolchains:
            return items.prefix(3).map(\.displayName).joined(separator: " · ")
        default:
            return items.allSatisfy(\.isAlwaysPermanent) ? "permanent" : nil
        }
    }

    private func toggleSelection(_ items: [CleanupItem]) {
        if model.selectedBytes(in: group) > 0 {
            model.select(items, false)
        } else {
            model.select(items.filter { $0.risk == .safe }, true)
        }
    }
}

/// A category's size relative to the largest one, with the selected part in full color.
private struct SizeShareBar: View {
    let tint: Color
    let total: Int64
    let selected: Int64
    let largest: Int64

    var body: some View {
        GeometryReader { proxy in
            let width = largest > 0 ? proxy.size.width * CGFloat(total) / CGFloat(largest) : 0
            let selectedWidth = total > 0 ? width * CGFloat(selected) / CGFloat(total) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Rectangle().fill(tint.opacity(0.25)).frame(width: width)
                Rectangle().fill(tint).frame(width: selectedWidth)
            }
            .clipShape(Capsule())
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

// MARK: - Cleaning

private struct CleaningView: View {
    @Environment(AppModel.self) private var model
    let cleaning: CleaningState

    var body: some View {
        let total = cleaning.totalBytes
        let processed = cleaning.processedBytes
        ScrollView {
            VStack(spacing: 0) {
                ProgressRing(fraction: total > 0 ? Double(processed) / Double(total) : 0) {
                    VStack(spacing: 2) {
                        Text(processed.fileSize)
                            .font(.system(size: 34, weight: .semibold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text("of \(total.fileSize)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 196, height: 196)
                .animation(.smooth(duration: 0.4), value: processed)

                Text("Cleaning \(min(cleaning.completed + 1, cleaning.items.count)) of \(cleaning.items.count)…")
                    .font(.system(size: 22, weight: .semibold))
                    .monospacedDigit()
                    .padding(.top, 24)
                Text(cleaning.mode == .moveToTrash
                     ? "Moving to the Trash. You can put anything back until you empty it."
                     : "Deleting permanently. This cannot be undone.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                Text(model.cleaningItemName ?? " ")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 620)
                    .padding(.top, 10)

                VStack(spacing: 0) {
                    ForEach(Array(cleaning.groups.enumerated()), id: \.element) { index, group in
                        if index > 0 { Divider().padding(.leading, 48) }
                        HStack(spacing: 10) {
                            GroupIcon(group: group, size: 24)
                            Text(group.title).font(.system(size: 13))
                            Spacer()
                            Text(cleaning.bytes(in: group).fileSize)
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            progressIcon(cleaning.progress(of: group))
                                .frame(width: 18)
                        }
                        .frame(height: 38)
                        .padding(.horizontal, 14)
                    }
                }
                .groupedBox()
                .frame(maxWidth: 520)
                .padding(.top, 24)
                .animation(.snappy, value: cleaning.completed)

                Button("Stop After Current Item") { model.cancel() }
                    .capsuleButtonStyle()
                    .controlSize(.large)
                    .padding(.top, 22)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func progressIcon(_ progress: CleaningState.GroupProgress) -> some View {
        switch progress {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .transition(.scale.combined(with: .opacity))
        case .running:
            ProgressView().controlSize(.small)
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Completion

private struct CompletionView: View {
    @Environment(AppModel.self) private var model
    let outcome: CleanupOutcome
    @Binding var selection: SidebarSelection?
    @State private var showsFailures = false

    var body: some View {
        let movedToTrash = model.cleaning?.mode == .moveToTrash
        ScrollView {
            VStack(spacing: 0) {
                Image(systemName: outcome.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 68))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(outcome.failures.isEmpty ? .white : .black.opacity(0.85), outcome.failures.isEmpty ? .green : .yellow)
                    .symbolEffect(.bounce, value: outcome.removed.count)

                Text("\(outcome.reclaimedBytes.fileSize) \(movedToTrash ? "cleaned up" : "freed")")
                    .font(.system(size: 58, weight: .semibold))
                    .monospacedDigit()
                    .padding(.top, 18)
                if let disk = model.diskSpace {
                    Text(movedToTrash
                         ? "It becomes available on Macintosh HD when you empty the Trash."
                         : "\(disk.availableBytes.fileSize) now available on Macintosh HD")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)

                    diskBar(disk)
                        .frame(maxWidth: 560)
                        .padding(.top, 24)
                }

                summary(movedToTrash: movedToTrash)
                    .frame(maxWidth: 620)
                    .padding(.top, 26)

                if showsFailures {
                    IssuesList(failures: outcome.failures)
                        .frame(maxWidth: 620)
                        .padding(.top, 10)
                }

                HStack(spacing: 12) {
                    Button("Show in History") { selection = .history }
                        .capsuleButtonStyle()
                    Button("Done") { model.showsCompletion = false }
                        .prominentActionStyle()
                        .buttonBorderShape(.capsule)
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.large)
                .padding(.top, 26)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 36)
            .frame(maxWidth: .infinity)
        }
    }

    private func diskBar(_ disk: DiskSpace) -> some View {
        let cleaned = min(outcome.reclaimedBytes, disk.usedBytes)
        let movedToTrash = model.cleaning?.mode == .moveToTrash
        // Trashed items still take space, so the freed part is carved out of the used space; a permanent delete has already moved it to available.
        let used = movedToTrash ? disk.usedBytes - cleaned : disk.usedBytes
        let available = movedToTrash ? disk.availableBytes : max(0, disk.availableBytes - cleaned)
        return VStack(spacing: 10) {
            DiskUsageBar(
                segments: [
                    .init(id: "used", bytes: used, color: .usedSpace),
                    .init(id: "cleaned", bytes: cleaned, color: .green),
                    .init(id: "available", bytes: available, color: .clear),
                ],
                height: 10
            )
            HStack(spacing: 16) {
                LegendDot(color: .usedSpace, title: "Used")
                LegendDot(color: .green, title: movedToTrash ? "In the Trash now" : "Freed just now")
                LegendDot(color: .availableSpace, title: movedToTrash ? "Available" : "Available before")
            }
        }
    }

    private func summary(movedToTrash: Bool) -> some View {
        let permanentCount = outcome.removed.filter(\.isAlwaysPermanent).count
        let failedBytes = outcome.failures.reduce(0) { $0 + $1.item.sizeInBytes }
        return VStack(spacing: 0) {
            SummaryRow(
                symbol: movedToTrash ? "trash" : "xmark.bin",
                tint: .secondary,
                title: movedToTrash ? "Moved to the Trash" : "Deleted permanently",
                detail: "\(outcome.reclaimedBytes.fileSize) in \(outcome.removed.count) items"
                    + (movedToTrash ? " · restorable until you empty the Trash" : "")
                    + (movedToTrash && permanentCount > 0 ? ". \(permanentCount) were removed by their own tools and skip the Trash." : "")
            ) {
                if movedToTrash {
                    Button("Show in Trash") { NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash")) }
                }
            }
            if !outcome.failures.isEmpty {
                Divider().padding(.leading, 46)
                SummaryRow(
                    symbol: "exclamationmark.triangle.fill",
                    tint: .yellow,
                    title: "\(outcome.failures.count) items skipped",
                    detail: "\(failedBytes.fileSize) · \(outcome.failures.first?.reason ?? "") They'll be picked up on the next scan."
                ) {
                    Button(showsFailures ? "Hide Items" : "Show Items") { showsFailures.toggle() }
                }
            }
            if outcome.removed.contains(where: { $0.risk == .safe }) {
                Divider().padding(.leading, 46)
                SummaryRow(
                    symbol: "arrow.triangle.2.circlepath",
                    tint: .secondary,
                    title: "Rebuilds on demand",
                    detail: "DerivedData, node_modules and caches come back the next time a tool needs them."
                ) {
                    EmptyView()
                }
            }
        }
        .groupedBox()
    }
}

private struct SummaryRow<Actions: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .symbolRenderingMode(.palette)
                .foregroundStyle(tint == .yellow ? Color.black.opacity(0.85) : tint, tint)
                .font(.system(size: 15))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions()
                .capsuleButtonStyle()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

// MARK: - Shared

/// The scan warnings or cleanup failures behind a notice's Show Items.
private struct IssuesList: View {
    private let rows: [(id: String, subject: String, message: String)]

    init(issues: [ScanIssue]) {
        rows = issues.prefix(100).map { ($0.id.uuidString, $0.subject, $0.message) }
    }

    init(failures: [CleanupFailure]) {
        rows = failures.map { ($0.id, $0.item.displayName, $0.reason) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows, id: \.id) { row in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.subject)
                            .font(.system(size: 11.5, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(row.message).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .frame(maxHeight: 180)
        .outlinedBox()
    }
}
