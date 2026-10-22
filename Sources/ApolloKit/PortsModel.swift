import ApolloKitCore
import AppKit
import Observation

@MainActor
@Observable
final class PortsModel {
    private(set) var ports: [ListeningPort] = []
    private(set) var hasLoaded = false
    private(set) var stoppingPortIDs: Set<ListeningPort.ID> = []
    /// Ports whose process ignored SIGTERM; the UI offers Force Stop for these.
    private(set) var unresponsivePortIDs: Set<ListeningPort.ID> = []
    var errorMessage: String?

    @ObservationIgnored private let scanner = PortScanner()
    @ObservationIgnored private let terminator = ProcessTerminator()
    @ObservationIgnored private var isReloading = false
    let homeDirectory = FileManager.default.homeDirectoryForCurrentUser

    /// Ports opened by the user's own tools, as opposed to macOS services.
    var developerPorts: [ListeningPort] {
        ports.filter { !$0.isSystemProcess }
    }

    func canStop(_ port: ListeningPort) -> Bool {
        terminator.refusal(for: port) == nil
    }

    func refusalReason(_ port: ListeningPort) -> String? {
        terminator.refusal(for: port)?.localizedDescription
    }

    func reload() {
        guard !isReloading else { return }
        isReloading = true
        let scanner = scanner
        Task {
            do {
                ports = try await scanner.listeningPorts()
            } catch {
                errorMessage = error.localizedDescription
            }
            let ids = Set(ports.map(\.id))
            unresponsivePortIDs.formIntersection(ids)
            hasLoaded = true
            isReloading = false
        }
    }

    /// Asks the process to quit, waits up to three seconds, then offers Force Stop if it is still running.
    func stop(_ port: ListeningPort, force: Bool = false) {
        guard !stoppingPortIDs.contains(port.id) else { return }
        do {
            try terminator.terminate(port, force: force)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        stoppingPortIDs.insert(port.id)
        unresponsivePortIDs.remove(port.id)
        let terminator = terminator

        Task {
            for _ in 0..<15 where terminator.isRunning(port.pid) {
                try? await Task.sleep(for: .milliseconds(200))
            }
            if terminator.isRunning(port.pid) {
                unresponsivePortIDs.insert(port.id)
            }
            stoppingPortIDs.remove(port.id)
            reload()
        }
    }

    func open(_ port: ListeningPort) {
        if let url = port.localURL { NSWorkspace.shared.open(url) }
    }

    func copyURL(_ port: ListeningPort) {
        guard let url = port.localURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    func revealProject(_ port: ListeningPort) {
        if let url = port.projectURL(homeDirectory: homeDirectory) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func openAirPlaySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.AirDrop-Handoff-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
