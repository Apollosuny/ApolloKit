import Foundation

/// A process accepting TCP connections on a local port. IPv4 and IPv6 sockets of the same process are merged.
public struct ListeningPort: Sendable, Hashable, Identifiable {
    public let port: Int
    public let pid: pid_t
    public let processName: String
    /// Bound addresses as `lsof` prints them: `*`, `127.0.0.1`, `[::1]`, …
    public let addresses: [String]
    public var userID: uid_t?
    public var executablePath: String?
    public var commandLine: String?
    public var workingDirectory: URL?

    public var id: String { "\(pid):\(port)" }

    public init(
        port: Int, pid: pid_t, processName: String, addresses: [String],
        userID: uid_t? = nil, executablePath: String? = nil, commandLine: String? = nil, workingDirectory: URL? = nil
    ) {
        self.port = port
        self.pid = pid
        self.processName = processName
        self.addresses = addresses
        self.userID = userID
        self.executablePath = executablePath
        self.commandLine = commandLine
        self.workingDirectory = workingDirectory
    }

    /// Reachable from other machines on the network, not only from this Mac.
    public var isExposed: Bool {
        addresses.contains { !Self.loopbackAddresses.contains($0) }
    }

    /// Part of macOS. Stopping these breaks system features and they are restarted anyway.
    public var isSystemProcess: Bool {
        guard let executablePath else { return false }
        return ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/"].contains { executablePath.hasPrefix($0) }
    }

    /// macOS' AirPlay Receiver (Control Center) holds 5000 and 7000, a common clash with Flask and other dev servers.
    public var isAirPlayReceiver: Bool {
        processName == "ControlCenter" && (port == 5000 || port == 7000)
    }

    /// The folder the process was started from, when it looks like a project rather than `/` or the home folder.
    public func projectURL(homeDirectory: URL) -> URL? {
        guard let workingDirectory else { return nil }
        let path = workingDirectory.standardizedFileURL.path
        guard path != "/", path != homeDirectory.standardizedFileURL.path else { return nil }
        return workingDirectory
    }

    public var localURL: URL? { URL(string: "http://localhost:\(port)") }

    private static let loopbackAddresses: Set<String> = ["127.0.0.1", "[::1]", "localhost"]
}

/// Lists listening TCP ports through `lsof` and enriches them with `ps`.
/// Without administrator rights `lsof` only reports the current user's processes, which are the ones that can be stopped.
public struct PortScanner: Sendable {
    public let runner: any ToolRunner

    private let lsof = URL(fileURLWithPath: "/usr/sbin/lsof")
    private let ps = URL(fileURLWithPath: "/bin/ps")

    public init(runner: any ToolRunner = ProcessToolRunner()) {
        self.runner = runner
    }

    public func listeningPorts() async throws -> [ListeningPort] {
        let listing = try await runner.run(ToolInvocation(executable: lsof, arguments: Self.listArguments), timeout: 10)
        // lsof exits 1 when nothing matches.
        guard listing.exitCode == 0 || listing.exitCode == 1 else {
            throw ToolRunnerError.failed(command: "lsof", exitCode: listing.exitCode, message: listing.errorText)
        }
        var ports = Self.parseListening(String(decoding: listing.standardOutput, as: UTF8.self))
        guard !ports.isEmpty else { return [] }

        let pids = Array(Set(ports.map(\.pid))).sorted().map(String.init).joined(separator: ",")
        async let directories = text(lsof, ["-a", "-p", pids, "-d", "cwd", "-F", "pn"])
        async let executables = text(ps, ["-ww", "-o", "pid=", "-o", "uid=", "-o", "comm=", "-p", pids])
        async let commands = text(ps, ["-ww", "-o", "pid=", "-o", "command=", "-p", pids])

        let directoryByPID = Self.parseWorkingDirectories(await directories)
        let executableByPID = Self.parseExecutables(await executables)
        let commandByPID = Self.parseCommands(await commands)

        for index in ports.indices {
            let pid = ports[index].pid
            ports[index].workingDirectory = directoryByPID[pid]
            ports[index].userID = executableByPID[pid]?.userID
            ports[index].executablePath = executableByPID[pid]?.path
            ports[index].commandLine = commandByPID[pid]
        }
        return ports
    }

    static let listArguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "+c", "0", "-F", "pcn"]

    /// Enrichment is best effort: a process that exited in between simply has no details.
    private func text(_ executable: URL, _ arguments: [String]) async -> String {
        guard let output = try? await runner.run(ToolInvocation(executable: executable, arguments: arguments), timeout: 10) else {
            return ""
        }
        return String(decoding: output.standardOutput, as: UTF8.self)
    }

    /// `lsof -F pcn`: a `p<pid>` line starts each process, followed by `c<command>`, then `f<fd>`/`n<address:port>` per socket.
    static func parseListening(_ text: String) -> [ListeningPort] {
        struct Key: Hashable { let pid: pid_t; let port: Int }
        var order: [Key] = []
        var names: [Key: String] = [:]
        var addresses: [Key: [String]] = [:]
        var pid: pid_t?
        var command = ""

        for line in text.split(separator: "\n") {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p":
                pid = pid_t(value)
                command = ""
            case "c":
                command = value
            case "n":
                guard let pid, let separator = value.lastIndex(of: ":"), let port = Int(value[value.index(after: separator)...]) else { continue }
                let address = String(value[..<separator])
                let key = Key(pid: pid, port: port)
                if addresses[key] == nil {
                    order.append(key)
                    names[key] = command
                }
                if !(addresses[key]?.contains(address) ?? false) {
                    addresses[key, default: []].append(address)
                }
            default:
                continue
            }
        }

        return order
            .map { ListeningPort(port: $0.port, pid: $0.pid, processName: names[$0] ?? "", addresses: addresses[$0] ?? []) }
            .sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    static func parseWorkingDirectories(_ text: String) -> [pid_t: URL] {
        var result: [pid_t: URL] = [:]
        var pid: pid_t?
        for line in text.split(separator: "\n") {
            if line.hasPrefix("p") {
                pid = pid_t(line.dropFirst())
            } else if line.hasPrefix("n"), let pid {
                result[pid] = URL(fileURLWithPath: String(line.dropFirst()), isDirectory: true)
            }
        }
        return result
    }

    /// `ps -o pid= -o uid= -o comm=`: the executable path is the rest of the line and may contain spaces.
    static func parseExecutables(_ text: String) -> [pid_t: (userID: uid_t, path: String)] {
        var result: [pid_t: (userID: uid_t, path: String)] = [:]
        for line in text.split(separator: "\n") {
            let columns = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard columns.count == 3, let pid = pid_t(columns[0]), let userID = uid_t(columns[1]) else { continue }
            result[pid] = (userID, String(columns[2]))
        }
        return result
    }

    static func parseCommands(_ text: String) -> [pid_t: String] {
        var result: [pid_t: String] = [:]
        for line in text.split(separator: "\n") {
            let columns = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard columns.count == 2, let pid = pid_t(columns[0]) else { continue }
            result[pid] = String(columns[1])
        }
        return result
    }
}

/// Stops the process behind a port. Refuses macOS processes, other users' processes and ApolloKit itself.
public struct ProcessTerminator: Sendable {
    public enum Failure: Error, LocalizedError, Equatable {
        case protected(String)
        case notPermitted(String)
        case failed(String, errno: Int32)

        public var errorDescription: String? {
            switch self {
            case .protected(let reason): reason
            case .notPermitted(let name): "\(name) belongs to another user or to the system and can't be stopped from here."
            case .failed(let name, let code): "Couldn't stop \(name): \(String(cString: strerror(code)))."
            }
        }
    }

    public let currentProcessID: pid_t
    public let currentUserID: uid_t
    /// Sends a signal and returns `0` or the `errno` value, like `kill(2)`.
    private let sendSignal: @Sendable (pid_t, Int32) -> Int32

    public init(
        currentProcessID: pid_t = getpid(),
        currentUserID: uid_t = getuid(),
        sendSignal: @escaping @Sendable (pid_t, Int32) -> Int32 = { kill($0, $1) == 0 ? 0 : errno }
    ) {
        self.currentProcessID = currentProcessID
        self.currentUserID = currentUserID
        self.sendSignal = sendSignal
    }

    public func refusal(for port: ListeningPort) -> Failure? {
        if port.pid <= 1 || port.pid == currentProcessID {
            return .protected("\(port.processName) can't be stopped.")
        }
        if port.isAirPlayReceiver {
            return .protected("Port \(port.port) is held by AirPlay Receiver. Turn it off in System Settings › General › AirDrop & Handoff.")
        }
        if port.isSystemProcess {
            return .protected("\(port.processName) is part of macOS.")
        }
        if let userID = port.userID, userID != currentUserID {
            return .notPermitted(port.processName)
        }
        return nil
    }

    /// `force` sends SIGKILL, which the process can't intercept; otherwise SIGTERM lets it shut down cleanly.
    public func terminate(_ port: ListeningPort, force: Bool = false) throws {
        if let refusal = refusal(for: port) { throw refusal }
        let result = sendSignal(port.pid, force ? SIGKILL : SIGTERM)
        switch result {
        case 0, ESRCH: return // ESRCH: already gone.
        case EPERM: throw Failure.notPermitted(port.processName)
        default: throw Failure.failed(port.processName, errno: result)
        }
    }

    public func isRunning(_ pid: pid_t) -> Bool {
        let result = sendSignal(pid, 0)
        return result == 0 || result == EPERM
    }
}
