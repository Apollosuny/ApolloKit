import ApolloKitCore
import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            ScanLocationsSettings()
                .tabItem { Label("Locations", systemImage: "folder") }
            RulesSettings()
                .tabItem { Label("Rules", systemImage: "list.bullet.rectangle") }
        }
        .frame(width: 620, height: 520)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLoginStatus = SMAppService.mainApp.status
    @State private var launchAtLoginError: String?

    var body: some View {
        @Bindable var preferences = model.preferences

        Form {
            Section {
                Toggle("Show ApolloKit in the menu bar", isOn: $preferences.showsMenuBarExtra)
                Toggle("Show free space next to the icon", isOn: $preferences.showsFreeSpaceInMenuBar)
                    .disabled(!preferences.showsMenuBarExtra)
            } header: {
                Text("Menu Bar")
            } footer: {
                Text("When the window is closed, ApolloKit keeps running in the menu bar and leaves the Dock.")
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLoginStatus == .enabled },
                    set: { setLaunchAtLogin($0) }
                ))
                if launchAtLoginStatus == .requiresApproval {
                    HStack {
                        Text("Allow ApolloKit in Login Items to finish enabling.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Could not update login item: \(error.localizedDescription)"
        }
        launchAtLoginStatus = SMAppService.mainApp.status
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
