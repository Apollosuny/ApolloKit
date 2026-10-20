import Foundation

public struct ToolInvocation: Sendable, Hashable {
    public let executable: URL
    public let arguments: [String]

    public init(executable: URL, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    public var commandLine: String {
        ([executable.lastPathComponent] + arguments).joined(separator: " ")
    }
}

public struct ToolOutput: Sendable {
    public let exitCode: Int32
    public let standardOutput: Data
    public let standardError: Data

    public init(exitCode: Int32, standardOutput: Data = Data(), standardError: Data = Data()) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var errorText: String {
        String(decoding: standardError, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum ToolRunnerError: Error, LocalizedError {
    case timedOut(String)
    case failed(command: String, exitCode: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let command):
            "\(command) timed out."
        case .failed(let command, let exitCode, let message):
            "\(command) failed (exit \(exitCode))\(message.isEmpty ? "." : ": \(message)")"
        }
    }
}

public protocol ToolRunner: Sendable {
    func run(_ invocation: ToolInvocation, timeout: TimeInterval) async throws -> ToolOutput
}

/// Executables for command-based cleanups, resolved once per scan.
public struct ToolEnvironment: Sendable {
    public let runner: any ToolRunner
    public let xcrun: URL?
    public let docker: URL?

    public init(runner: any ToolRunner, xcrun: URL?, docker: URL?) {
        self.runner = runner
        self.xcrun = xcrun
        self.docker = docker
    }

    public static var system: ToolEnvironment {
        let home = NSHomeDirectory()
        // GUI apps do not inherit the shell PATH, so probe the usual install locations.
        // `isExecutableFile` follows symlinks, which skips dangling links left by uninstalled tools.
        let dockerCandidates = [
            "/usr/local/bin/docker",
            "/opt/homebrew/bin/docker",
            "\(home)/.docker/bin/docker",
            "\(home)/.orbstack/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker",
            "/Applications/OrbStack.app/Contents/MacOS/xbin/docker",
        ]
        return ToolEnvironment(
            runner: ProcessToolRunner(),
            xcrun: firstExecutable(["/usr/bin/xcrun"]),
            docker: firstExecutable(dockerCandidates)
        )
    }

    private static func firstExecutable(_ paths: [String]) -> URL? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
}

public struct ProcessToolRunner: ToolRunner {
    private static let environment: [String: String] = {
        var environment = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let searchPath = [
            "/usr/local/bin", "/opt/homebrew/bin", "\(home)/.docker/bin",
            "/Applications/Docker.app/Contents/Resources/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        environment["PATH"] = (searchPath + [environment["PATH"]].compactMap { $0 }).joined(separator: ":")
        return environment
    }()

    public init() {}

    public func run(_ invocation: ToolInvocation, timeout: TimeInterval) async throws -> ToolOutput {
        let execution = ProcessExecution(invocation: invocation, environment: Self.environment)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                execution.start(timeout: timeout) { continuation.resume(with: $0) }
            }
        } onCancel: {
            execution.terminate()
        }
    }
}

/// Owns one `Process` and its pipes. Pipes are drained on background threads while the process
/// runs, otherwise output larger than the pipe buffer (64 KB) would deadlock the child.
private final class ProcessExecution: @unchecked Sendable {
    private let process = Process()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let lock = NSLock()
    private var standardOutput = Data()
    private var standardError = Data()
    private var didTimeOut = false
    private let commandLine: String

    init(invocation: ToolInvocation, environment: [String: String]) {
        commandLine = invocation.commandLine
        process.executableURL = invocation.executable
        process.arguments = invocation.arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = errorPipe
    }

    func start(timeout: TimeInterval, completion: @escaping @Sendable (Result<ToolOutput, any Error>) -> Void) {
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global().async {
            let data = self.outputPipe.fileHandleForReading.readDataToEndOfFile()
            self.lock.withLock { self.standardOutput = data }
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            let data = self.errorPipe.fileHandleForReading.readDataToEndOfFile()
            self.lock.withLock { self.standardError = data }
            group.leave()
        }
        group.enter()
        process.terminationHandler = { _ in group.leave() }

        do {
            try process.run()
        } catch {
            // Unblock the readers; the termination handler never fires for a process that did not launch.
            try? outputPipe.fileHandleForWriting.close()
            try? errorPipe.fileHandleForWriting.close()
            completion(.failure(error))
            return
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            guard self.process.isRunning else { return }
            self.lock.withLock { self.didTimeOut = true }
            self.process.terminate()
        }

        group.notify(queue: .global()) {
            self.lock.withLock {
                if self.didTimeOut {
                    completion(.failure(ToolRunnerError.timedOut(self.commandLine)))
                } else {
                    completion(.success(ToolOutput(
                        exitCode: self.process.terminationStatus,
                        standardOutput: self.standardOutput,
                        standardError: self.standardError
                    )))
                }
            }
        }
    }

    func terminate() {
        if process.isRunning {
            process.terminate()
        }
    }
}
