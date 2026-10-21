import ApolloKitCore
import SwiftUI

enum SidebarSelection: Hashable {
    case overview
    case group(RuleGroup)
    case uninstaller
    case startupItems

    /// Tools have their own review-and-remove flow, so the Smart Scan clean bar stays hidden there.
    var showsCleanBar: Bool {
        switch self {
        case .overview, .group: true
        case .uninstaller, .startupItems: false
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
                case .group(let group):
                    GroupDetailView(group: group)
                case .uninstaller:
                    UninstallerView()
                case .startupItems:
                    StartupItemsView()
                }
            }
            .overlay(alignment: .bottom) {
                if (selection ?? .overview).showsCleanBar {
                    CleanBar()
                }
            }
            .animation(.smooth, value: model.isBusy)
        }
        .onChange(of: model.isBusy) { _, isBusy in
            // Scan and clean progress live on the Smart Scan screen; a background scan leaves the user where they are.
            if isBusy, !model.isBackgroundScan { selection = .overview }
        }
        .onAppear {
            model.openMainWindow = { [openWindow] in openWindow(id: ApolloKitApp.mainWindowID) }
            if model.consumeHideWindowAtLaunch() {
                dismissWindow(id: ApolloKitApp.mainWindowID)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.isBusy {
                    Button("Cancel", systemImage: "stop.circle") { model.cancel() }
                } else {
                    Button("Scan", systemImage: "magnifyingglass") { model.startScan() }
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
            Label("Smart Scan", systemImage: "sparkle.magnifyingglass")
                .tag(SidebarSelection.overview)

            Section("Categories") {
                ForEach(RuleGroup.allCases) { group in
                    HStack(spacing: 8) {
                        GroupIcon(group: group, size: 20)
                        Text(group.title)
                            .lineLimit(1)
                        Spacer()
                        if model.report != nil {
                            Text(model.totalBytes(in: group).fileSize)
                                .font(.callout)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(SidebarSelection.group(group))
                }
            }

            Section("Tools") {
                Label("Uninstaller", systemImage: "trash.square")
                    .tag(SidebarSelection.uninstaller)
                Label("Startup Items", systemImage: "power.circle")
                    .tag(SidebarSelection.startupItems)
            }
        }
    }
}

struct RiskBadge: View {
    let risk: RiskLevel

    var body: some View {
        if risk == .caution {
            Text("Caution")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .foregroundStyle(.orange)
                .background(.orange.opacity(0.15), in: Capsule())
                .help("Expensive to regenerate or may contain data worth keeping.")
        }
    }
}
