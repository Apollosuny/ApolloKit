import ApolloKitCore
import SwiftUI

struct GroupDetailView: View {
    /// Narrows the list; selecting is left to the checkboxes, the Select menu and the clean bar.
    enum ItemFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case safe = "Safe Items"
        case unused30Days = "30 Days"
        case unused6Months = "6 Months"

        var id: Self { self }

        var help: String {
            switch self {
            case .all: "Every item in this category"
            case .safe: "Items that rebuild by themselves"
            case .unused30Days: "Items not modified or used in the last 30 days"
            case .unused6Months: "Items not modified or used in the last 6 months"
            }
        }

        func includes(_ item: CleanupItem) -> Bool {
            switch self {
            case .all: true
            case .safe: item.risk == .safe
            case .unused30Days: item.isUnused(forDays: 30)
            case .unused6Months: item.isUnused(forDays: 182)
            }
        }
    }

    let group: RuleGroup
    @Binding var selection: SidebarSelection?

    @Environment(AppModel.self) private var model
    @State private var sortOrder = [KeyPathComparator(\CleanupItem.sizeInBytes, order: .reverse)]
    @State private var highlighted = Set<CleanupItem.ID>()
    @State private var filter = ItemFilter.all
    @State private var searchText = ""

    var body: some View {
        let allItems = model.items(in: group)
        let items = allItems
            .filter { filter.includes($0) && matchesSearch($0) }
            .sorted(using: sortOrder)

        VStack(alignment: .leading, spacing: 14) {
            header(allItems: allItems)
            Text(group.explanation)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: 760, alignment: .leading)

            if allItems.isEmpty {
                emptyState
            } else if items.isEmpty {
                Group {
                    if searchText.isEmpty {
                        ContentUnavailableView("No \(filter.rawValue) Items", systemImage: "line.3.horizontal.decrease.circle", description: Text("Nothing in this category matches the filter."))
                    } else {
                        ContentUnavailableView.search(text: searchText)
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                table(items)
                    .outlinedBox()
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Room for the floating clean bar.
        .padding(.bottom, allItems.isEmpty ? 20 : 90)
        .navigationTitle(group.title)
        .navigationSubtitle("Smart Scan")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Filter items")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back to Smart Scan", systemImage: "chevron.left") { selection = .overview }
                    .help("Back to Smart Scan")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                selectMenu(items)
                Button("Show in Finder", systemImage: "folder") { model.revealInFinder(revealTargets(items)) }
                    .help("Show the highlighted items, or all shown, in Finder")
                    .disabled(revealTargets(items).isEmpty)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        Group {
            if model.report == nil {
                ContentUnavailableView {
                    Label("Not Scanned Yet", systemImage: group.symbolName)
                } description: {
                    Text("Run a Smart Scan to find reclaimable space.")
                } actions: {
                    Button("Scan Now") { model.startScan() }
                        .prominentActionStyle()
                        .buttonBorderShape(.capsule)
                        .disabled(model.isBusy)
                }
            } else {
                ContentUnavailableView("Nothing to Clean", systemImage: "checkmark.circle", description: Text("This category is already tidy."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func matchesSearch(_ item: CleanupItem) -> Bool {
        searchText.isEmpty
            || item.displayName.localizedCaseInsensitiveContains(searchText)
            || item.rule.title.localizedCaseInsensitiveContains(searchText)
            || item.locationDescription.localizedCaseInsensitiveContains(searchText)
    }

    private func revealTargets(_ items: [CleanupItem]) -> [URL] {
        let chosen = highlighted.isEmpty ? items : items.filter { highlighted.contains($0.id) }
        return chosen.compactMap(\.url)
    }

    private func header(allItems: [CleanupItem]) -> some View {
        let total = allItems.reduce(0) { $0 + $1.sizeInBytes }
        let selected = model.selectedBytes(in: group)

        return HStack(spacing: 14) {
            GroupIcon(group: group, size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.title)
                    .font(.system(size: 22, weight: .bold))
                Text("\(total.fileSize) in \(allItems.count) items · \(selected.fileSize) selected")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy, value: selected)
            }
            Spacer()
            Picker("Show", selection: $filter) {
                ForEach(ItemFilter.allCases) { Text($0.rawValue).help($0.help).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(allItems.isEmpty)
        }
    }

    private func selectMenu(_ items: [CleanupItem]) -> some View {
        Menu("Select", systemImage: "checklist") {
            Button("Safe Items") {
                model.select(items, false)
                model.select(items.filter { $0.risk == .safe }, true)
            }
            Button("Not Used in 30 Days") { selectOnly(items.filter { $0.isUnused(forDays: 30) }, in: items) }
            Button("Not Used in 6 Months") { selectOnly(items.filter { $0.isUnused(forDays: 182) }, in: items) }
            Divider()
            Button("All Shown") { model.select(items, true) }
            Button("None") { model.select(items, false) }
        }
        .disabled(items.isEmpty || model.isBusy)
    }

    private func selectOnly(_ chosen: [CleanupItem], in items: [CleanupItem]) {
        model.select(items, false)
        model.select(chosen, true)
    }

    private func table(_ items: [CleanupItem]) -> some View {
        Table(items, selection: $highlighted, sortOrder: $sortOrder) {
            TableColumn("") { item in
                Toggle("", isOn: model.selectionBinding(for: item))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(model.isBusy)
            }
            .width(16)

            TableColumn("Name", value: \.displayName) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName)
                        .lineLimit(1)
                    Text(item.locationDescription)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.vertical, 4)
                .help(item.locationDescription)
            }

            TableColumn("Safety", value: \.risk.rawValue) { item in
                SafetyLabel(risk: item.risk, isPermanent: item.isAlwaysPermanent)
            }
            .width(min: 80, ideal: 110)

            TableColumn("Reason") { item in
                Text(reason(for: item))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(item.concerns.map(\.explanation).joined(separator: "\n").nonEmpty ?? item.rule.detail)
            }
            .width(min: 160, ideal: 220)

            // Large files carry Spotlight's last-opened date; everything else its modification date.
            TableColumn(group == .largeFiles ? "Last Used" : "Last Changed", value: \.lastModifiedSortKey) { item in
                if let date = item.lastModified {
                    Text(date, format: .relative(presentation: .named))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 90, ideal: 110)

            TableColumn("Size", value: \.sizeInBytes) { item in
                Text(item.sizeInBytes.fileSize)
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 84)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: CleanupItem.ID.self) { ids in
            let chosen = items.filter { ids.contains($0.id) }
            let locations = chosen.compactMap(\.url)
            Button("Show in Finder") { model.revealInFinder(locations) }
                .disabled(locations.isEmpty)
            Divider()
            Button("Mark for Cleanup") { model.select(chosen, true) }
            Button("Unmark") { model.select(chosen, false) }
            Divider()
            Button("Never Clean This") { model.neverClean(chosen.compactMap(\.fileURL)) }
                .disabled(chosen.allSatisfy { $0.fileURL == nil })
        } primaryAction: { ids in
            model.revealInFinder(items.filter { ids.contains($0.id) }.compactMap(\.url))
        }
    }

    /// Why an item is listed, or why it needs a decision: its concerns first, otherwise what the rule finds.
    private func reason(for item: CleanupItem) -> String {
        if !item.concerns.isEmpty {
            return item.concerns.map(\.summary).joined(separator: " · ")
        }
        return item.isUnused(forDays: 182) ? "\(item.rule.title) · not used in 6 months" : item.rule.title
    }
}

extension CleanupItem {
    /// Unknown dates count as recent, so a missing date never makes an item look abandoned.
    func isUnused(forDays days: Double) -> Bool {
        (lastModified ?? .distantFuture) < Date.now.addingTimeInterval(-days * 24 * 60 * 60)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// Inline bar showing an item's size relative to the largest item in view.
struct SizeBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(tint.opacity(0.75))
                .frame(width: max(3, proxy.size.width * fraction))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 5)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .accessibilityHidden(true)
    }
}
