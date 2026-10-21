import ApolloKitCore
import SwiftUI

struct GroupDetailView: View {
    enum RiskFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case safe = "Safe"
        case caution = "Caution"

        var id: Self { self }

        func includes(_ item: CleanupItem) -> Bool {
            switch self {
            case .all: true
            case .safe: item.rule.risk == .safe
            case .caution: item.rule.risk == .caution
            }
        }
    }

    let group: RuleGroup

    @Environment(AppModel.self) private var model
    @State private var sortOrder = [KeyPathComparator(\CleanupItem.sizeInBytes, order: .reverse)]
    @State private var highlighted = Set<CleanupItem.ID>()
    @State private var riskFilter = RiskFilter.all
    @State private var searchText = ""

    var body: some View {
        let allItems = model.items(in: group)
        let items = allItems
            .filter { riskFilter.includes($0) && matchesSearch($0) }
            .sorted(using: sortOrder)

        VStack(spacing: 0) {
            header(allItems: allItems, visible: items)
            Divider()
            if allItems.isEmpty {
                ContentUnavailableView(
                    model.report == nil ? "Not scanned yet" : "Nothing to clean",
                    systemImage: group.symbolName,
                    description: Text(model.report == nil ? "Run a Smart Scan to find reclaimable space." : "This category is already tidy.")
                )
                .frame(maxHeight: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxHeight: .infinity)
            } else {
                table(items, largest: items.map(\.sizeInBytes).max() ?? 0)
            }
        }
        .navigationTitle(group.title)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Filter items")
    }

    private func matchesSearch(_ item: CleanupItem) -> Bool {
        searchText.isEmpty
            || item.displayName.localizedCaseInsensitiveContains(searchText)
            || item.rule.title.localizedCaseInsensitiveContains(searchText)
            || item.locationDescription.localizedCaseInsensitiveContains(searchText)
    }

    private func header(allItems: [CleanupItem], visible items: [CleanupItem]) -> some View {
        let total = allItems.reduce(0) { $0 + $1.sizeInBytes }
        let selected = model.selectedBytes(in: group)

        return HStack(spacing: 14) {
            GroupIcon(group: group, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(total.fileSize)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                Text("\(allItems.count) items · \(selected.fileSize) selected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Picker("Risk", selection: $riskFilter) {
                ForEach(RiskFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Menu("Select") {
                Button("Safe Items") {
                    model.select(items, false)
                    model.select(items.filter { $0.rule.risk == .safe }, true)
                }
                Button("Not Used in 30 Days") {
                    let cutoff = Date.now.addingTimeInterval(-30 * 24 * 60 * 60)
                    model.select(items, false)
                    model.select(items.filter { ($0.lastModified ?? .distantFuture) < cutoff }, true)
                }
                .help("Select items not modified or used in the last 30 days")
                Divider()
                Button("All Shown") { model.select(items, true) }
                Button("None") { model.select(items, false) }
            }
            .fixedSize()
        }
        .disabled(allItems.isEmpty || model.isBusy)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func table(_ items: [CleanupItem], largest: Int64) -> some View {
        Table(items, selection: $highlighted, sortOrder: $sortOrder) {
            TableColumn("") { item in
                Toggle("", isOn: model.selectionBinding(for: item))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(model.isBusy)
            }
            .width(20)

            TableColumn("Name", value: \.displayName) { item in
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.displayName)
                    Text(item.locationDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(item.locationDescription)
            }

            TableColumn("Category", value: \.rule.title) { item in
                HStack(spacing: 6) {
                    Text(item.rule.title)
                    RiskBadge(risk: item.rule.risk)
                }
                .help(item.rule.detail)
            }
            .width(min: 160, ideal: 220)

            TableColumn("Size", value: \.sizeInBytes) { item in
                HStack(spacing: 8) {
                    SizeBar(fraction: largest > 0 ? Double(item.sizeInBytes) / Double(largest) : 0, tint: group.tint)
                    Text(item.sizeInBytes.fileSize)
                        .monospacedDigit()
                        .frame(minWidth: 64, alignment: .trailing)
                }
            }
            .width(min: 140, ideal: 160)

            TableColumn("Modified", value: \.lastModifiedSortKey) { item in
                if let date = item.lastModified {
                    Text(date, format: .relative(presentation: .named))
                        .foregroundStyle(.secondary)
                }
            }
            .width(110)
        }
        .contextMenu(forSelectionType: CleanupItem.ID.self) { ids in
            let chosen = items.filter { ids.contains($0.id) }
            let locations = chosen.compactMap(\.url)
            Button("Reveal in Finder") { model.revealInFinder(locations) }
                .disabled(locations.isEmpty)
            Divider()
            Button("Mark for Cleanup") { model.select(chosen, true) }
            Button("Unmark") { model.select(chosen, false) }
        } primaryAction: { ids in
            model.revealInFinder(items.filter { ids.contains($0.id) }.compactMap(\.url))
        }
    }
}

/// Inline bar showing an item's size relative to the largest item in view.
private struct SizeBar: View {
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
