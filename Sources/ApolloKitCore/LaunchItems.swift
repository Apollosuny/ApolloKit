import Foundation

/// A launchd job definition (`.plist` in a LaunchAgents or LaunchDaemons folder).
public struct LaunchItem: Sendable, Hashable, Identifiable {
    public enum Scope: String, Sendable, CaseIterable {
        /// `~/Library/LaunchAgents`: owned by the user, can be disabled or removed without a password.
        case userAgent
        /// `/Library/LaunchAgents`: installed by an administrator, runs in every user's session.
        case systemAgent
        /// `/Library/LaunchDaemons`: installed by an administrator, runs as root.
        case systemDaemon

        public var title: String {
            switch self {
            case .userAgent: "Your Launch Agents"
            case .systemAgent: "Launch Agents for All Users"
            case .systemDaemon: "System Daemons"
            }
        }
    }

    public let url: URL
    public let label: String
    public let scope: Scope
    /// `Program`, or the first of `ProgramArguments`.
    public let programPath: String?
    public let associatedBundleIdentifiers: [String]
    public let runsAtLoad: Bool
    public let keepsAlive: Bool
    public let programExists: Bool

    public var id: String { url.path }
    public var isUserEditable: Bool { scope == .userAgent }

    /// The program was uninstalled but its job definition was left behind.
    public var isOrphaned: Bool { programPath != nil && !programExists }

    /// The `.app` bundle containing the program, if any (e.g. `/Applications/Docker.app`).
    public var owningAppURL: URL? {
        guard let programPath else { return nil }
        let components = (programPath as NSString).pathComponents
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(components[...index])))
    }

    init?(plistURL: URL, scope: Scope, fileManager: FileManager = .default) {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        self.url = plistURL.standardizedFileURL
        self.scope = scope
        self.label = plist["Label"] as? String ?? plistURL.deletingPathExtension().lastPathComponent
        let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
        self.programPath = program
        self.associatedBundleIdentifiers = (plist["AssociatedBundleIdentifiers"] as? [String])
            ?? (plist["AssociatedBundleIdentifiers"] as? String).map { [$0] }
            ?? []
        self.runsAtLoad = plist["RunAtLoad"] as? Bool ?? false
        self.keepsAlive = (plist["KeepAlive"] as? Bool) ?? (plist["KeepAlive"] is [String: Any])
        // Bare command names are resolved through PATH by launchd; only absolute paths can be checked.
        if let program, program.hasPrefix("/") {
            self.programExists = fileManager.fileExists(atPath: program)
        } else {
            self.programExists = true
        }
    }
}

/// Runtime state of jobs in the user's GUI launchd domain.
public struct LaunchItemStates: Sendable, Equatable {
    public var loadedLabels: Set<String> = []
    public var runningLabels: Set<String> = []
    public var disabledLabels: Set<String> = []

    public init(loadedLabels: Set<String> = [], runningLabels: Set<String> = [], disabledLabels: Set<String> = []) {
        self.loadedLabels = loadedLabels
        self.runningLabels = runningLabels
        self.disabledLabels = disabledLabels
    }
}

/// Reads launchd job definitions and enables, disables or unloads the user's own agents through `launchctl`.
public struct LaunchItemManager: Sendable {
    /// Rule attached to a job definition moved to the Trash; not part of `RuleCatalog.all`.
    public static let removalRule = CleanupRule(
        id: "startup.launchAgent", title: "Launch Agent",
        detail: "A launchd job definition. Removing it stops the job from starting again.",
        group: .apps, risk: .caution, locators: []
    )

    public let homeDirectory: URL
    public let systemLibrary: URL
    public let runner: any ToolRunner
    public let userID: uid_t

    private let launchctl = URL(fileURLWithPath: "/bin/launchctl")
    private var domain: String { "gui/\(userID)" }

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        systemLibrary: URL = URL(fileURLWithPath: "/Library"),
        runner: any ToolRunner = ProcessToolRunner(),
        userID: uid_t = getuid()
    ) {
        self.homeDirectory = homeDirectory
        self.systemLibrary = systemLibrary
        self.runner = runner
        self.userID = userID
    }

    public func items() -> [LaunchItem] {
        let folders: [(URL, LaunchItem.Scope)] = [
            (homeDirectory.appendingPathComponent("Library/LaunchAgents"), .userAgent),
            (systemLibrary.appendingPathComponent("LaunchAgents"), .systemAgent),
            (systemLibrary.appendingPathComponent("LaunchDaemons"), .systemDaemon),
        ]
        return folders.flatMap { folder, scope in
            let plists = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return plists
                .filter { $0.pathExtension == "plist" }
                .compactMap { LaunchItem(plistURL: $0, scope: scope) }
                .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        }
    }

    public func states() async -> LaunchItemStates {
        var states = LaunchItemStates()
        if let list = try? await run(["list"]), list.exitCode == 0 {
            (states.loadedLabels, states.runningLabels) = Self.parseList(String(decoding: list.standardOutput, as: UTF8.self))
        }
        if let disabled = try? await run(["print-disabled", domain]), disabled.exitCode == 0 {
            states.disabledLabels = Self.parseDisabled(String(decoding: disabled.standardOutput, as: UTF8.self))
        }
        return states
    }

    /// Persistently disables the job (survives logout) and stops it if it is loaded.
    public func disable(_ item: LaunchItem) async throws {
        try requireEditable(item)
        try await runChecked(["disable", "\(domain)/\(item.label)"])
        // Not loaded is fine: the job is disabled either way.
        _ = try? await run(["bootout", "\(domain)/\(item.label)"])
    }

    public func enable(_ item: LaunchItem) async throws {
        try requireEditable(item)
        try await runChecked(["enable", "\(domain)/\(item.label)"])
        // Fails harmlessly when the job is already loaded.
        _ = try? await run(["bootstrap", domain, item.url.path])
    }

    /// Unloads the job so its plist can be moved to the Trash without launchd restarting it.
    public func unload(_ item: LaunchItem) async throws {
        try requireEditable(item)
        _ = try? await run(["bootout", "\(domain)/\(item.label)"])
    }

    private func requireEditable(_ item: LaunchItem) throws {
        guard item.isUserEditable else {
            throw ToolRunnerError.failed(command: "launchctl", exitCode: 1, message: "\(item.label) is installed for all users and needs an administrator.")
        }
    }

    private func run(_ arguments: [String]) async throws -> ToolOutput {
        try await runner.run(ToolInvocation(executable: launchctl, arguments: arguments), timeout: 15)
    }

    private func runChecked(_ arguments: [String]) async throws {
        let output = try await run(arguments)
        guard output.exitCode == 0 else {
            throw ToolRunnerError.failed(command: "launchctl \(arguments.joined(separator: " "))", exitCode: output.exitCode, message: output.errorText)
        }
    }

    /// `launchctl list`: `PID<TAB>Status<TAB>Label`, PID is `-` when the job is loaded but not running.
    static func parseList(_ text: String) -> (loaded: Set<String>, running: Set<String>) {
        var loaded = Set<String>()
        var running = Set<String>()
        for line in text.split(separator: "\n").dropFirst() {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 3 else { continue }
            let label = String(columns[2])
            loaded.insert(label)
            if columns[0] != "-" { running.insert(label) }
        }
        return (loaded, running)
    }

    /// `launchctl print-disabled`: `"label" => disabled` (older systems print `=> true`).
    static func parseDisabled(_ text: String) -> Set<String> {
        var disabled = Set<String>()
        for line in text.split(separator: "\n") {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard value == "disabled" || value == "true" else { continue }
            disabled.insert(parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
        }
        return disabled
    }
}
