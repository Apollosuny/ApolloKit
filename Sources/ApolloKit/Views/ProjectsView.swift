import ApolloKitCore
import SwiftUI

/// Smart Scan's project build artifacts grouped by project, so whole projects you no longer work on can be cleaned.
struct ProjectsView: View {
    @Environment(AppModel.self) private var model
    @State private var sortOrder = [KeyPathComparator(\ProjectRow.lastActivitySortKey)]
    @State private var highlighted = Set<ProjectRow.ID>()
    @State private var searchText = ""

    var body: some View {
        let allProjects = model.projects
        let projects = allProjects.filter(matchesSearch).sorted(using: sortOrder)

        VStack(spacing: 0) {
            header(allProjects)
            Divider()
            if allProjects.isEmpty {
                emptyState
            } else if projects.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxHeight: .infinity)
            } else {
                table(projects, largest: projects.map(\.totalBytes).max() ?? 0)
            }
        }
        .navigationTitle("Projects")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Filter projects")
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.preferences.projectRoots.isEmpty {
            ContentUnavailableView {
                Label("No project folders", systemImage: "folder.badge.questionmark")
            } description: {
                Text("Add the folders that hold your code.")
            } actions: {
                Button("Add Folder…") { addFolders() }
            }
            .frame(maxHeight: .infinity)
        } else if model.report == nil {
            ContentUnavailableView {
                Label("Not scanned yet", systemImage: "hourglass")
            } description: {
                Text("Run a Smart Scan to find build artifacts in your projects.")
            } actions: {
                Button("Scan") { model.startScan() }
            }
            .frame(maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "No build artifacts",
                systemImage: "hourglass",
                description: Text("None of your projects has build artifacts to clean.")
            )
            .frame(maxHeight: .infinity)
        }
    }

    /// New folders are only searched by a scan, so one starts right away.
    private func addFolders() {
        let urls = ProjectFolderPanel.choose()
        guard !urls.isEmpty else { return }
        model.preferences.addProjectRoots(urls)
        model.startScan()
    }

    private func matchesSearch(_ project: ProjectRow) -> Bool {
        searchText.isEmpty
            || project.name.localizedCaseInsensitiveContains(searchText)
            || project.summary.root.path.localizedCaseInsensitiveContains(searchText)
    }

    private func header(_ projects: [ProjectRow]) -> some View {
        let stale = projects.filter(\.isStale)
        let staleBytes = stale.reduce(0) { $0 + $1.totalBytes }
        let allItems = projects.flatMap(\.items)

        return HStack(spacing: 14) {
            GroupIcon(group: .projectArtifacts, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(staleBytes.fileSize) in \(stale.count) stale projects")
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                Text("Not changed in \(model.preferences.activeProjectDays) days · \(projects.count) projects with build artifacts")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Button("Add Folder…", systemImage: "folder.badge.plus") { addFolders() }
                .help("Search another folder for projects")
                .disabled(model.isBusy)
            Menu("Select") {
                Button("Stale Projects") {
                    model.select(allItems, false)
                    model.select(stale.flatMap(\.items), true)
                }
                .help("Select the build artifacts of projects not changed in \(model.preferences.activeProjectDays) days")
                Divider()
                Button("All") { model.select(allItems, true) }
                Button("None") { model.select(allItems, false) }
            }
            .fixedSize()
            .disabled(projects.isEmpty || model.isBusy)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func table(_ projects: [ProjectRow], largest: Int64) -> some View {
        Table(projects, selection: $highlighted, sortOrder: $sortOrder) {
            TableColumn("") { project in
                Toggle("", sources: project.items.map(model.selectionBinding), isOn: \.self)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(model.isBusy)
            }
            .width(20)

            TableColumn("Project", value: \.name) { project in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(project.name)
                        if !project.isStale {
                            ConcernBadge(concern: .activeProject(lastActivity: project.lastActivitySortKey))
                        }
                    }
                    Text(project.summary.root.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(project.summary.root.path)
            }

            TableColumn("Build Artifacts") { project in
                Text(project.artifactNames)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(project.items.map(\.locationDescription).joined(separator: "\n"))
            }
            .width(min: 140, ideal: 200)

            TableColumn("Size", value: \.totalBytes) { project in
                HStack(spacing: 8) {
                    SizeBar(fraction: largest > 0 ? Double(project.totalBytes) / Double(largest) : 0, tint: RuleGroup.projectArtifacts.tint)
                    Text(project.totalBytes.fileSize)
                        .monospacedDigit()
                        .frame(minWidth: 64, alignment: .trailing)
                }
            }
            .width(min: 140, ideal: 160)

            TableColumn("Last Changed", value: \.lastActivitySortKey) { project in
                if let date = project.summary.lastActivity {
                    Text(date, format: .relative(presentation: .named))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Unknown")
                        .foregroundStyle(.tertiary)
                }
            }
            .width(110)
        }
        .contextMenu(forSelectionType: ProjectRow.ID.self) { ids in
            let chosen = projects.filter { ids.contains($0.id) }
            Button("Reveal in Finder") { model.revealInFinder(chosen.map(\.summary.root)) }
            Divider()
            Button("Mark for Cleanup") { model.select(chosen.flatMap(\.items), true) }
            Button("Unmark") { model.select(chosen.flatMap(\.items), false) }
            Divider()
            Button("Never Clean This Project") { model.neverClean(chosen.map(\.summary.root)) }
        } primaryAction: { ids in
            model.revealInFinder(projects.filter { ids.contains($0.id) }.map(\.summary.root))
        }
    }
}
