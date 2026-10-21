import ApolloKitCore
import SwiftUI

enum SidebarSelection: Hashable {
    case overview
    case group(RuleGroup)
    case uninstaller
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarSelection? = .overview

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
                }
            }
            .overlay(alignment: .bottom) {
                // The uninstaller has its own review-and-remove flow.
                if selection != .uninstaller {
                    CleanBar()
                }
            }
            .animation(.smooth, value: model.isBusy)
        }
        .onChange(of: model.isBusy) { _, isBusy in
            // Scan and clean progress live on the Smart Scan screen.
            if isBusy { selection = .overview }
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
