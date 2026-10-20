import ApolloKitCore
import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ScanLocationsSettings()
                .tabItem { Label("Locations", systemImage: "folder") }
            RulesSettings()
                .tabItem { Label("Rules", systemImage: "list.bullet.rectangle") }
        }
        .frame(width: 620, height: 520)
    }
}

private struct ScanLocationsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var highlighted = Set<URL>()

    var body: some View {
        let preferences = model.preferences

        VStack(alignment: .leading, spacing: 10) {
            Text("Project folders are searched recursively for build artifacts such as node_modules, .build, target and Pods.")
                .foregroundStyle(.secondary)

            List(preferences.projectRoots, id: \.self, selection: $highlighted) { url in
                Label(url.path, systemImage: "folder")
            }
            .listStyle(.bordered)

            HStack {
                Button("Add Folder…", systemImage: "plus") { chooseFolders() }
                Button("Remove", systemImage: "minus") {
                    preferences.projectRoots.removeAll { highlighted.contains($0) }
                    highlighted.removeAll()
                }
                .disabled(highlighted.isEmpty)
            }
        }
        .padding(20)
    }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        if panel.runModal() == .OK {
            model.preferences.addProjectRoots(panel.urls)
        }
    }
}

private struct RulesSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let preferences = model.preferences

        Form {
            ForEach(RuleGroup.allCases) { group in
                Section(group.title) {
                    ForEach(RuleCatalog.all.filter { $0.group == group }) { rule in
                        Toggle(isOn: Binding(
                            get: { preferences.isEnabled(rule) },
                            set: { preferences.setEnabled($0, for: rule) }
                        )) {
                            HStack(spacing: 6) {
                                Text(rule.title)
                                RiskBadge(risk: rule.risk)
                            }
                            Text(rule.detail)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
