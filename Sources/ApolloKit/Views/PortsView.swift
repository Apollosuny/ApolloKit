import ApolloKitCore
import SwiftUI

struct PortsView: View {
    @Environment(AppModel.self) private var model
    @State private var searchText = ""
    @State private var pendingStop: ListeningPort?

    private var portsModel: PortsModel { model.ports }

    var body: some View {
        let ports = portsModel.ports.filter(matchesSearch)
        let developer = ports.filter { !$0.isSystemProcess }
        let system = ports.filter(\.isSystemProcess)

        List {
            if let airPlay = ports.first(where: \.isAirPlayReceiver) {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "airplay.video")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("AirPlay Receiver is using port \(String(airPlay.port))").font(.headline)
                            Text("Dev servers that default to 5000 or 7000 fail to start while it is on.")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open AirDrop & Handoff") { portsModel.openAirPlaySettings() }
                    }
                    .padding(.vertical, 4)
                }
            }

            if !developer.isEmpty {
                Section("Your Apps and Servers") {
                    ForEach(developer) { port in
                        PortRow(port: port) { pendingStop = port }
                    }
                }
            }
            if !system.isEmpty {
                Section {
                    ForEach(system) { port in
                        PortRow(port: port) { pendingStop = port }
                    }
                } header: {
                    Text("macOS Services")
                } footer: {
                    Text("Part of macOS and restarted automatically, so they can't be stopped here.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            if !portsModel.hasLoaded {
                ProgressView()
            } else if ports.isEmpty {
                if searchText.isEmpty {
                    ContentUnavailableView("No ports in use", systemImage: "network", description: Text("Nothing is listening for connections right now."))
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
        .navigationTitle("Ports")
        .navigationSubtitle(portsModel.hasLoaded ? "\(portsModel.ports.count) listening" : "")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Port, process or project")
        .toolbar {
            ToolbarItem {
                Button("Reload", systemImage: "arrow.clockwise") { portsModel.reload() }
            }
        }
        .task {
            // Servers start and stop all the time while developing; keep the list live while it is on screen.
            while !Task.isCancelled {
                portsModel.reload()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .confirmationDialog(
            pendingStop.map { "Stop \($0.processName) on port \(String($0.port))?" } ?? "",
            isPresented: Binding(get: { pendingStop != nil }, set: { if !$0 { pendingStop = nil } }),
            presenting: pendingStop
        ) { port in
            Button("Stop") { portsModel.stop(port) }
            Button("Cancel", role: .cancel) {}
        } message: { port in
            Text(stopMessage(port))
        }
        .alert("Couldn't stop the process", isPresented: Binding(
            get: { portsModel.errorMessage != nil },
            set: { if !$0 { portsModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(portsModel.errorMessage ?? "")
        }
    }

    private func stopMessage(_ port: ListeningPort) -> String {
        var lines = ["Process \(port.pid) is asked to quit, like pressing Ctrl-C. Unsaved work in it may be lost."]
        let others = portsModel.ports.filter { $0.pid == port.pid && $0.port != port.port }.map { String($0.port) }
        if !others.isEmpty {
            lines.append("It also frees port \(others.joined(separator: ", ")).")
        }
        return lines.joined(separator: "\n\n")
    }

    private func matchesSearch(_ port: ListeningPort) -> Bool {
        guard !searchText.isEmpty else { return true }
        return [String(port.port), port.processName, port.commandLine ?? "", port.workingDirectory?.path ?? ""]
            .contains { $0.localizedCaseInsensitiveContains(searchText) }
    }
}

private struct PortRow: View {
    @Environment(AppModel.self) private var model
    let port: ListeningPort
    let onStop: () -> Void

    private var portsModel: PortsModel { model.ports }

    var body: some View {
        let project = port.projectURL(homeDirectory: portsModel.homeDirectory)
        let isStopping = portsModel.stoppingPortIDs.contains(port.id)

        HStack(spacing: 12) {
            Text(String(port.port))
                .font(.title3.weight(.semibold).monospacedDigit())
                .frame(minWidth: 64, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(port.processName).lineLimit(1)
                    if let project {
                        Label(project.lastPathComponent, systemImage: "folder")
                            .labelStyle(.titleAndIcon)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    ExposureBadge(isExposed: port.isExposed)
                }
                Text(port.commandLine ?? port.executablePath ?? "PID \(port.pid)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .help(port.commandLine ?? "")

            Spacer()

            Button("Open", systemImage: "safari") { portsModel.open(port) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Open http://localhost:\(String(port.port))")

            if isStopping {
                ProgressView().controlSize(.small).frame(width: 60)
            } else if portsModel.unresponsivePortIDs.contains(port.id) {
                Button("Force Stop") { portsModel.stop(port, force: true) }
                    .help("The process ignored the request to quit. Force Stop ends it immediately.")
            } else if portsModel.canStop(port) {
                Button("Stop", action: onStop)
            } else {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.tertiary)
                    .frame(width: 60)
                    .help(portsModel.refusalReason(port) ?? "")
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Open in Browser") { portsModel.open(port) }
            Button("Copy URL") { portsModel.copyURL(port) }
            if project != nil {
                Button("Reveal Project in Finder") { portsModel.revealProject(port) }
            }
            if portsModel.canStop(port) {
                Divider()
                Button("Stop…", action: onStop)
                Button("Force Stop") { portsModel.stop(port, force: true) }
            }
        }
    }
}

private struct ExposureBadge: View {
    let isExposed: Bool

    var body: some View {
        if isExposed {
            Text("Network")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 5)
                .foregroundStyle(.orange)
                .background(.orange.opacity(0.15), in: Capsule())
                .help("Listening on all interfaces: other devices on your network can connect.")
        }
    }
}
