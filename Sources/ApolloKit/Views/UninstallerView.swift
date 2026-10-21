import ApolloKitCore
import AppKit
import SwiftUI

struct UninstallerView: View {
    private struct AppRow: Identifiable {
        let app: InstalledApp
        let size: Int64?

        var id: InstalledApp.ID { app.id }
        var name: String { app.name }
        var sizeSortKey: Int64 { size ?? -1 }
        var lastUsedSortKey: Date { app.lastUsed ?? .distantPast }
    }

    @Environment(AppModel.self) private var model
    @State private var searchText = ""
    @State private var sortOrder = [KeyPathComparator(\AppRow.sizeSortKey, order: .reverse)]

    private var uninstaller: UninstallerModel { model.uninstaller }

    var body: some View {
        @Bindable var uninstaller = uninstaller
        let rows = uninstaller.apps
            .filter { searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) || $0.bundleIdentifier.localizedCaseInsensitiveContains(searchText) }
            .map { AppRow(app: $0, size: uninstaller.appSizes[$0.id]) }
            .sorted(using: sortOrder)

        VStack(spacing: 0) {
            if let result = uninstaller.lastResult, uninstaller.selectedAppID == nil {
                ResultBanner(result: result)
                Divider()
            }
            Table(rows, selection: $uninstaller.selectedAppID, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { row in
                    HStack(spacing: 8) {
                        AppIconView(url: row.app.url, size: 22)
                        Text(row.app.name)
                        if !uninstaller.canRemove(row.app) {
                            Text("System")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .opacity(uninstaller.canRemove(row.app) ? 1 : 0.55)
                }
                TableColumn("Version") { row in
                    Text(row.app.version ?? "—").foregroundStyle(.secondary)
                }
                .width(90)
                TableColumn("Size", value: \.sizeSortKey) { row in
                    Group {
                        if let size = row.size {
                            Text(size.fileSize)
                        } else {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(90)
                TableColumn("Last Used", value: \.lastUsedSortKey) { row in
                    if let date = row.app.lastUsed {
                        Text(date, format: .relative(presentation: .named)).foregroundStyle(.secondary)
                    } else {
                        Text("Unknown").foregroundStyle(.tertiary)
                    }
                }
                .width(120)
            }
            .contextMenu(forSelectionType: InstalledApp.ID.self) { ids in
                Button("Reveal in Finder") {
                    uninstaller.revealInFinder(uninstaller.apps.filter { ids.contains($0.id) }.map(\.url))
                }
            }
            .overlay {
                if uninstaller.isLoadingApps && uninstaller.apps.isEmpty {
                    ProgressView("Looking for apps…")
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: { $0.pathExtension == "app" }) else { return false }
                if let app = uninstaller.apps.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                    uninstaller.selectedAppID = app.id
                    return true
                }
                return false
            }
        }
        .navigationTitle("Uninstaller")
        .navigationSubtitle("\(uninstaller.apps.count) apps")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search apps")
        .toolbar {
            ToolbarItem {
                Button("Reload", systemImage: "arrow.clockwise") { uninstaller.loadApps() }
                    .disabled(uninstaller.isLoadingApps)
            }
        }
        .inspector(isPresented: Binding(
            get: { uninstaller.selectedAppID != nil },
            set: { if !$0 { uninstaller.selectedAppID = nil } }
        )) {
            if let app = uninstaller.selectedApp {
                AppFootprintInspector(app: app)
                    .inspectorColumnWidth(min: 320, ideal: 360, max: 480)
            }
        }
        .onAppear {
            if uninstaller.apps.isEmpty { uninstaller.loadApps() }
        }
    }
}

private struct AppFootprintInspector: View {
    @Environment(AppModel.self) private var model
    let app: InstalledApp

    @State private var isConfirming = false

    private var uninstaller: UninstallerModel { model.uninstaller }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(16)
            Divider()

            if !uninstaller.canRemove(app) {
                ContentUnavailableView(
                    "Part of macOS",
                    systemImage: "lock.fill",
                    description: Text("Apple apps and ApolloKit itself can't be removed here.")
                )
            } else if uninstaller.isLoadingFootprint {
                ProgressView("Finding app data…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                itemList
                Divider()
                footer
                    .padding(16)
            }
        }
        .confirmationDialog("Uninstall \(app.name)?", isPresented: $isConfirming) {
            Button("Move to Trash") { uninstaller.uninstall(app, mode: .moveToTrash) }
            Button("Delete Permanently", role: .destructive) { uninstaller.uninstall(app, mode: .deletePermanently) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AppIconView(url: app.url, size: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.title3.weight(.semibold))
                Text([app.version.map { "Version \($0)" }, app.bundleIdentifier].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
        }
    }

    private var itemList: some View {
        List {
            ForEach(uninstaller.footprint) { item in
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { uninstaller.selectedItemIDs.contains(item.id) },
                        set: { uninstaller.select([item], $0) }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(item.displayName).lineLimit(1).truncationMode(.middle)
                            if item.rule == AppUninstaller.Rules.possiblyRelated {
                                Text("Name match")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 5)
                                    .foregroundStyle(.orange)
                                    .background(.orange.opacity(0.15), in: Capsule())
                                    .help(item.rule.detail)
                            }
                        }
                        Text(item.rule.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(item.sizeInBytes.fileSize)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .help(item.locationDescription)
                .contextMenu {
                    Button("Reveal in Finder") { uninstaller.revealInFinder(item.url.map { [$0] } ?? []) }
                }
            }
        }
        .listStyle(.inset)
        .disabled(uninstaller.isRemoving)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let result = uninstaller.lastResult {
                ResultBanner(result: result)
            }
            if uninstaller.isRunning(app) {
                HStack {
                    Label("\(app.name) is running", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Quit \(app.name)") { uninstaller.quit(app) }
                }
                .font(.callout)
            } else if uninstaller.mayNeedAdministrator(app) {
                Label("Installed by an administrator or the App Store. If removal fails, use Finder or Launchpad.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(uninstaller.selectedBytes.fileSize)
                        .font(.headline)
                        .monospacedDigit()
                    Text("\(uninstaller.selectedItemIDs.count) of \(uninstaller.footprint.count) items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if uninstaller.isRemoving {
                    ProgressView().controlSize(.small)
                }
                Button(appIsSelected ? "Uninstall…" : "Remove Data…") { isConfirming = true }
                    .prominentActionStyle()
                    .controlSize(.large)
                    .disabled(uninstaller.selectedItemIDs.isEmpty || uninstaller.isRunning(app) || uninstaller.isRemoving)
            }
        }
    }

    private var appIsSelected: Bool {
        uninstaller.selectedItemIDs.contains(app.url.path)
    }

    private var confirmationMessage: String {
        var lines = ["\(uninstaller.selectedItemIDs.count) items, \(uninstaller.selectedBytes.fileSize)."]
        if !appIsSelected {
            lines.append("The app itself is not selected, so it stays installed and only its data is removed.")
        }
        lines.append("Moving to Trash lets you restore everything if the app misbehaves later.")
        return lines.joined(separator: "\n\n")
    }
}

private struct ResultBanner: View {
    let result: UninstallerModel.Result

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                "\(result.appName): removed \(result.removedCount) items, \(result.reclaimedBytes.fileSize)",
                systemImage: result.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(result.failures.isEmpty ? Color.green : .orange)
            .font(.callout.weight(.medium))
            ForEach(result.failures.prefix(5), id: \.self) { failure in
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct AppIconView: View {
    let url: URL
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
