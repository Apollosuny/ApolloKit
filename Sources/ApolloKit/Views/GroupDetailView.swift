import ApolloKitCore
import SwiftUI

struct GroupDetailView: View {
    let group: RuleGroup

    @Environment(AppModel.self) private var model
    @State private var sortOrder = [KeyPathComparator(\CleanupItem.sizeInBytes, order: .reverse)]
    @State private var highlighted = Set<CleanupItem.ID>()

    var body: some View {
        let items = model.items(in: group).sorted(using: sortOrder)

        VStack(spacing: 0) {
            header(items)
            Divider()
            if items.isEmpty {
                ContentUnavailableView(
                    model.report == nil ? "Not scanned yet" : "Nothing to clean",
                    systemImage: group.symbolName
                )
                .frame(maxHeight: .infinity)
            } else {
                table(items)
            }
        }
        .navigationTitle(group.title)
    }

    private func header(_ items: [CleanupItem]) -> some View {
        HStack {
            Text("\(items.count) items · \(items.reduce(0) { $0 + $1.sizeInBytes }.formatted(.byteCount(style: .file)))")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Select Safe") {
                model.select(items, false)
                model.select(items.filter { $0.rule.risk == .safe }, true)
            }
            Button("Select Older Than 30 Days") {
                let cutoff = Date.now.addingTimeInterval(-30 * 24 * 60 * 60)
                model.select(items, false)
                model.select(items.filter { ($0.lastModified ?? .distantFuture) < cutoff }, true)
            }
            .help("Select items not modified or used in the last 30 days")
            Button("Select All") { model.select(items, true) }
            Button("Deselect All") { model.select(items, false) }
        }
        .controlSize(.small)
        .disabled(items.isEmpty || model.isBusy)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func table(_ items: [CleanupItem]) -> some View {
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
                Text(item.sizeInBytes.formatted(.byteCount(style: .file)))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(90)

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
