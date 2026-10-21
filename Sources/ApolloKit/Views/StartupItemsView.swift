import ApolloKitCore
import SwiftUI

struct StartupItemsView: View {
    @Environment(AppModel.self) private var model
    @State private var searchText = ""
    @State private var pendingRemoval: [LaunchItem] = []

    private var startup: StartupItemsModel { model.startupItems }

    var body: some View {
        let items = startup.items.filter(matchesSearch)

        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "info.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("Apps that register through System Settings › Login Items & Extensions are managed there.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Login Items") { startup.openLoginItemsSettings() }
                }
                .padding(.vertical, 4)

                if !startup.removableOrphans.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title3)
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(startup.removableOrphans.count) agents point to programs that no longer exist")
                                .font(.headline)
                            Text("Usually left behind by apps that were removed. They fail on every login.")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove Broken…") { pendingRemoval = startup.removableOrphans }
                    }
                    .padding(.vertical, 4)
                }
            }

            ForEach(LaunchItem.Scope.allCases, id: \.self) { scope in
                let scoped = items.filter { $0.scope == scope }
                if !scoped.isEmpty {
                    Section {
                        ForEach(scoped) { item in
                            LaunchItemRow(item: item) { pendingRemoval = [item] }
                        }
                    } header: {
                        Text(scope.title)
                    } footer: {
                        if scope != .userAgent {
                            Text("Installed for all users. Changing these needs an administrator; use Reveal in Finder to remove one.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .overlay {
            if startup.isLoading && startup.items.isEmpty {
                ProgressView()
            } else if !startup.isLoading && startup.items.isEmpty {
                ContentUnavailableView("No launch agents", systemImage: "power.circle")
            }
        }
        .navigationTitle("Startup Items")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search items")
        .toolbar {
            ToolbarItem {
                Button("Reload", systemImage: "arrow.clockwise") { startup.reload() }
                    .disabled(startup.isLoading)
            }
        }
        .onAppear { startup.reload() }
        .confirmationDialog(
            pendingRemoval.count == 1 ? "Remove \(pendingRemoval[0].label)?" : "Remove \(pendingRemoval.count) launch agents?",
            isPresented: Binding(get: { !pendingRemoval.isEmpty }, set: { if !$0 { pendingRemoval = [] } })
        ) {
            Button("Move to Trash", role: .destructive) {
                startup.remove(pendingRemoval)
                pendingRemoval = []
            }
            Button("Cancel", role: .cancel) { pendingRemoval = [] }
        } message: {
            Text("The job is stopped and its definition moved to the Trash. Restore it from the Trash and log out and back in to bring it back.")
        }
        .alert("Couldn't update startup item", isPresented: Binding(
            get: { startup.errorMessage != nil },
            set: { if !$0 { startup.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(startup.errorMessage ?? "")
        }
    }

    private func matchesSearch(_ item: LaunchItem) -> Bool {
        searchText.isEmpty
            || item.label.localizedCaseInsensitiveContains(searchText)
            || (item.programPath?.localizedCaseInsensitiveContains(searchText) ?? false)
    }
}

private struct LaunchItemRow: View {
    @Environment(AppModel.self) private var model
    let item: LaunchItem
    let requestRemoval: () -> Void

    private var startup: StartupItemsModel { model.startupItems }

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 3) {
                Text(item.label)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    if item.isOrphaned { Badge(text: "Missing program", color: .orange) }
                    if startup.isRunning(item) { Badge(text: "Running", color: .green) }
                    if !startup.isEnabled(item) { Badge(text: "Disabled", color: .secondary) }
                    if item.runsAtLoad { Badge(text: "Starts automatically", color: .blue) }
                    if item.keepsAlive { Badge(text: "Keep alive", color: .purple) }
                }
            }
            Spacer()
            if startup.busyItemIDs.contains(item.id) {
                ProgressView().controlSize(.small)
            }
            if item.isUserEditable {
                Toggle("Enabled", isOn: Binding(
                    get: { startup.isEnabled(item) },
                    set: { startup.setEnabled($0, for: item) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(startup.busyItemIDs.contains(item.id))
                .help(startup.isEnabled(item) ? "Stop this agent from starting" : "Allow this agent to start")
            }
        }
        .padding(.vertical, 2)
        .help(item.url.path)
        .contextMenu {
            Button("Reveal Job File in Finder") { startup.revealInFinder([item.url]) }
            if let program = item.programPath, item.programExists, program.hasPrefix("/") {
                Button("Reveal Program in Finder") { startup.revealInFinder([URL(fileURLWithPath: program)]) }
            }
            if item.isUserEditable {
                Divider()
                Button("Remove…", role: .destructive, action: requestRemoval)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let app = item.owningAppURL, FileManager.default.fileExists(atPath: app.path) {
            AppIconView(url: app, size: 28)
        } else {
            Image(systemName: item.scope == .systemDaemon ? "gearshape.2" : "gearshape")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        }
    }

    private var subtitle: String {
        if let app = item.owningAppURL {
            return app.deletingPathExtension().lastPathComponent + (item.isOrphaned ? " (not installed)" : "")
        }
        return item.programPath ?? item.associatedBundleIdentifiers.first ?? "No program"
    }
}

private struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }
}
