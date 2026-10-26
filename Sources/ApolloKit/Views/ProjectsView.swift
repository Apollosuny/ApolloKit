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

        VStack(alignment: .leading, spacing: 14) {
            header(allProjects)
            if !model.preferences.projectRoots.isEmpty {
                rootsLine
            }
            if allProjects.isEmpty {
                emptyState
            } else if projects.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxHeight: .infinity)
            } else {
                table(projects)
                    .outlinedBox()
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Room for the floating clean bar.
        .padding(.bottom, allProjects.isEmpty ? 20 : 90)
        .navigationTitle("Projects")
        .navigationSubtitle(subtitle(allProjects))
        .searchable(text: $searchText, placement: .toolbar, prompt: "Filter projects")
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.preferences.projectRoots.isEmpty {
            ContentUnavailableView {
                Label("No Project Folders", systemImage: "folder.badge.questionmark")
            } description: {
                Text("Add the folders that hold your code.")
            } actions: {
                Button("Add Folder…") { addFolders() }
                    .prominentActionStyle()
                    .buttonBorderShape(.capsule)
            }
            .frame(maxHeight: .infinity)
        } else if model.report == nil {
            ContentUnavailableView {
                Label("Not Scanned Yet", systemImage: "hourglass")
            } description: {
                Text("Run a Smart Scan to find build artifacts in your projects.")
            } actions: {
                Button("Scan Now") { model.startScan() }
                    .prominentActionStyle()
                    .buttonBorderShape(.capsule)
                    .disabled(model.isBusy)
            }
            .frame(maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "Nothing to Clean",
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

    private func subtitle(_ projects: [ProjectRow]) -> String {
        let folders = model.preferences.projectRoots.count
        return "\(folders == 1 ? "1 folder" : "\(folders) folders") · \(projects.count) projects"
    }

    private func header(_ projects: [ProjectRow]) -> some View {
        let stale = projects.filter(\.isStale)
        let staleBytes = stale.reduce(0) { $0 + $1.totalBytes }
        let allItems = projects.flatMap(\.items)

        return HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(stale.count == 1 ? "\(staleBytes.fileSize) in 1 stale project" : "\(staleBytes.fileSize) in \(stale.count) stale projects")
                    .font(.system(size: 26, weight: .bold))
                    .monospacedDigit()
                Text("Only build artifacts are removed — they come back with npm install, cargo build or pod install. Source code and Git history are never touched.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 600, alignment: .leading)
            }
            Spacer()
            Button("Add Folder…") { addFolders() }
                .help("Search another folder for projects")
                .disabled(model.isBusy)
            Button("Select Stale Projects") {
                model.select(allItems, false)
                model.select(stale.flatMap(\.items), true)
            }
            .help("Select the build artifacts of projects not changed in \(model.preferences.activeProjectDays) days")
            .disabled(stale.isEmpty || model.isBusy)
        }
        .capsuleButtonStyle()
    }

    private var rootsLine: some View {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let roots = model.preferences.projectRoots.map { url in
            url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
        }
        return HStack(spacing: 6) {
            Text("Scanning")
            ForEach(Array(roots.enumerated()), id: \.offset) { index, root in
                if index > 0 { Text("·") }
                Text(root)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
            }
            Text("Stale means no file changes in \(model.preferences.activeProjectDays) days.")
                .padding(.leading, 8)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func table(_ projects: [ProjectRow]) -> some View {
        Table(projects, selection: $highlighted, sortOrder: $sortOrder) {
            TableColumn("") { project in
                Toggle("", sources: project.items.map(model.selectionBinding), isOn: \.self)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(model.isBusy)
            }
            .width(16)

            TableColumn("Project", value: \.name) { project in
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.name)
                        .fontWeight(.semibold)
                    Text(project.summary.root.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.vertical, 3)
                .help(project.summary.root.path)
            }

            TableColumn("Build Artifacts") { project in
                Text(project.artifactNames)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(project.items.map(\.locationDescription).joined(separator: "\n"))
            }
            .width(min: 140, ideal: 200)

            TableColumn("Last Changed", value: \.lastActivitySortKey) { project in
                if let date = project.summary.lastActivity {
                    HStack(spacing: 6) {
                        if !project.isStale {
                            Circle().fill(.blue).frame(width: 7, height: 7)
                            Text("Active · \(date.formatted(.relative(presentation: .named)))")
                        } else {
                            Text(date, format: .relative(presentation: .named))
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(project.isStale ? .secondary : .primary)
                    .help(project.isStale ? "Not changed in \(model.preferences.activeProjectDays) days" : CleanupConcern.activeProject(lastActivity: date).explanation)
                } else {
                    Text("Unknown")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }
            .width(min: 120, ideal: 170)

            TableColumn("Size", value: \.totalBytes) { project in
                Text(project.totalBytes.fileSize)
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 84)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
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
