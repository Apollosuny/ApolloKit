import ApolloKitCore
import SwiftUI

enum SidebarSelection: Hashable {
    case overview
    case projects
    case group(RuleGroup)
    case diskMap
    case systemData
    case uninstaller
    case startupItems
    case ports
    case history

    /// Tools have their own review-and-remove flow, so the Smart Scan clean bar stays hidden there.
    var showsCleanBar: Bool {
        switch self {
        case .overview, .projects, .group: true
        case .diskMap, .systemData, .uninstaller, .startupItems, .ports, .history: false
        }
    }

    /// A category screen cleans only what it shows; Smart Scan cleans the selection in every category.
    var cleanScope: RuleGroup? {
        switch self {
        case .group(let group): group
        case .projects: .projectArtifacts
        default: nil
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarSelection? = .overview
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        } detail: {
            Group {
                switch selection ?? .overview {
                case .overview:
                    OverviewView(selection: $selection)
                case .projects:
                    ProjectsView()
                case .group(let group):
                    GroupDetailView(group: group, selection: $selection)
                case .diskMap:
                    DiskMapView()
                case .systemData:
                    SystemDataView()
                case .uninstaller:
                    UninstallerView()
                case .startupItems:
                    StartupItemsView()
                case .ports:
                    PortsView()
                case .history:
                    HistoryView()
                }
            }
            .overlay(alignment: .bottom) {
                if (selection ?? .overview).showsCleanBar {
                    CleanBar(screen: selection ?? .overview)
                }
            }
            .animation(.smooth, value: model.isBusy)
        }
        .onChange(of: model.isBusy) { _, isBusy in
            // Scan and clean progress live on the Smart Scan screen; a background scan leaves the user where they are.
            if isBusy, !model.isBackgroundScan { selection = .overview }
        }
        .onChange(of: model.requestedSidebarSelection) { _, requested in
            guard let requested else { return }
            selection = requested
            model.requestedSidebarSelection = nil
        }
        .onAppear {
            if let requested = model.requestedSidebarSelection {
                selection = requested
                model.requestedSidebarSelection = nil
            }
            model.openMainWindow = { [openWindow] in openWindow(id: ApolloKitApp.mainWindowID) }
            if model.consumeHideWindowAtLaunch() {
                dismissWindow(id: ApolloKitApp.mainWindowID)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.isBusy {
                    Button("Stop", systemImage: "stop.fill") { model.cancel() }
                } else {
                    Button(model.report == nil ? "Scan" : "Rescan", systemImage: "arrow.clockwise") { model.startScan() }
                        .help("Scan caches and project build artifacts (⌘R)")
                }
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .frame(minWidth: 960, minHeight: 600)
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarSelection?

    var body: some View {
        List(selection: $selection) {
            Section("Clean") {
                Label("Smart Scan", systemImage: "sparkle.magnifyingglass")
                    .badge(badge(model.report == nil ? nil : model.safeBytes))
                    .tag(SidebarSelection.overview)
                ForEach(RuleGroup.allCases) { group in
                    HStack(spacing: 8) {
                        GroupIcon(group: group, size: 18)
                        Text(group.title)
                            .lineLimit(1)
                    }
                    .padding(.leading, 12)
                    .badge(categoryBadge(group))
                    .tag(SidebarSelection.group(group))
                }
                Label("Projects", systemImage: "hourglass")
                    .badge(badge(model.report == nil ? nil : model.projects.filter(\.isStale).reduce(0) { $0 + $1.totalBytes }))
                    .tag(SidebarSelection.projects)
            }

            Section("Explore") {
                Label("Disk Map", systemImage: "chart.pie")
                    .tag(SidebarSelection.diskMap)
                Label("System Data", systemImage: "internaldrive")
                    .badge(badge(model.systemData.scannedAt == nil ? nil : model.systemData.totalBytes))
                    .tag(SidebarSelection.systemData)
            }

            Section("Apps") {
                Label("Uninstaller", systemImage: "trash.square")
                    .tag(SidebarSelection.uninstaller)
                Label("Startup Items", systemImage: "power.circle")
                    .tag(SidebarSelection.startupItems)
            }

            Section("Tools") {
                Label("Ports", systemImage: "network")
                    .badge(model.ports.developerPorts.count)
                    .tag(SidebarSelection.ports)
                Label("History", systemImage: "clock.arrow.circlepath")
                    .tag(SidebarSelection.history)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let disk = model.diskSpace {
                SidebarDiskSummary(disk: disk)
            }
        }
    }

    /// Live totals while scanning, results afterwards, "—" for a scanned category with nothing in it.
    private func categoryBadge(_ group: RuleGroup) -> Text? {
        if model.isScanning {
            let bytes = model.liveBytesByGroup[group] ?? 0
            return bytes > 0 ? Text(bytes.fileSize) : nil
        }
        guard model.report != nil else { return nil }
        let bytes = model.totalBytes(in: group)
        return Text(bytes > 0 ? bytes.fileSize : "—")
    }

    private func badge(_ bytes: Int64?) -> Text? {
        guard let bytes, bytes > 0 else { return nil }
        return Text(bytes.fileSize)
    }
}

private struct SidebarDiskSummary: View {
    let disk: DiskSpace

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Macintosh HD")
                Spacer()
                Text("\(disk.availableBytes.fileSize) available")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            DiskUsageBar(
                segments: [
                    .init(id: "used", bytes: disk.usedBytes, color: Color(nsColor: .systemGray)),
                    .init(id: "free", bytes: disk.availableBytes, color: .clear),
                ],
                height: 5
            )
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

struct RiskBadge: View {
    let risk: RiskLevel

    var body: some View {
        if risk == .caution {
            SafetyLabel(risk: .caution)
                .font(.caption)
        }
    }
}
