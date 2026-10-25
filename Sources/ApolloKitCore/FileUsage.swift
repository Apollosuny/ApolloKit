import Foundation

/// Files the current user's processes had open at one moment: open files, working directories,
/// and loaded executables and libraries. Tools that are not running leave no trace here.
public struct FileUsageSnapshot: Sendable {
    struct OpenFile: Sendable, Hashable {
        let processName: String
        let path: String
    }

    let openFiles: Set<OpenFile>

    init(openFiles: Set<OpenFile>) {
        self.openFiles = openFiles
    }

    /// Names of the processes with something open at or below each URL, keyed by the URL's path.
    /// URLs nothing has open are left out.
    public func processes(using urls: [URL]) -> [String: [String]] {
        let targets = Set(urls.map(\.path))
        guard !targets.isEmpty else { return [:] }
        var found: [String: Set<String>] = [:]
        for file in openFiles {
            // Walks up from the open file so each lookup is a set hit rather than a prefix scan over all items.
            var path = Substring(file.path)
            while !path.isEmpty {
                if targets.contains(String(path)) { found[String(path), default: []].insert(file.processName) }
                guard let slash = path.lastIndex(of: "/") else { break }
                path = path[..<slash]
            }
        }
        return found.mapValues { $0.sorted() }
    }
}

/// Takes `FileUsageSnapshot`s with `lsof`, which takes about a third of a second for all of a user's processes.
/// Without administrator rights it only sees the current user's processes, which are the ones using their caches.
public struct FileUsageMonitor: Sendable {
    public let runner: any ToolRunner
    let userID: uid_t
    let currentProcessID: pid_t

    private let lsof = URL(fileURLWithPath: "/usr/sbin/lsof")

    public init(runner: any ToolRunner = ProcessToolRunner(), userID: uid_t = getuid(), currentProcessID: pid_t = getpid()) {
        self.runner = runner
        self.userID = userID
        self.currentProcessID = currentProcessID
    }

    var arguments: [String] {
        ["-nP", "-w", "-u", String(userID), "+c", "0", "-F", "pcn"]
    }

    public func snapshot() async throws -> FileUsageSnapshot {
        let output = try await runner.run(ToolInvocation(executable: lsof, arguments: arguments), timeout: 20)
        // lsof exits 1 when some files could not be listed; what it did list is still valid.
        guard output.exitCode == 0 || output.exitCode == 1 else {
            throw ToolRunnerError.failed(command: "lsof", exitCode: output.exitCode, message: output.errorText)
        }
        let text = String(decoding: output.standardOutput, as: UTF8.self)
        return FileUsageSnapshot(openFiles: Self.parse(text, excludingProcessID: currentProcessID))
    }

    /// `lsof -F pcn`: `p<pid>` starts each process, `c<command>` names it, then `f<fd>`/`n<name>` per open file.
    /// Sockets and pipes have names that are not absolute paths and are skipped.
    static func parse(_ text: String, excludingProcessID: pid_t) -> Set<FileUsageSnapshot.OpenFile> {
        var files = Set<FileUsageSnapshot.OpenFile>()
        var processID: pid_t?
        var processName = ""
        for line in text.split(separator: "\n") {
            guard let field = line.first else { continue }
            let value = line.dropFirst()
            switch field {
            case "p":
                processID = pid_t(value)
                processName = ""
            case "c":
                processName = String(value)
            case "n":
                guard let processID, processID != excludingProcessID, value.hasPrefix("/") else { continue }
                files.insert(.init(processName: processName.isEmpty ? "pid \(processID)" : processName, path: String(value)))
            default:
                continue
            }
        }
        return files
    }
}
