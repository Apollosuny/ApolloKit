import Foundation
import Testing
@testable import ApolloKitCore

private func output(_ text: String, exitCode: Int32 = 0) -> ToolOutput {
    ToolOutput(exitCode: exitCode, standardOutput: Data(text.utf8))
}

@Suite struct PortScannerTests {
    private let listing = """
    p739
    cControlCenter
    f9
    n*:7000
    f10
    n*:7000
    p4211
    cnode
    f22
    n127.0.0.1:5173
    f23
    n[::1]:5173
    p4300
    cGoogle Chrome Helper
    f40
    n127.0.0.1:9222
    """

    @Test func mergesSocketsOfTheSameProcessAndPort() {
        let ports = PortScanner.parseListening(listing)

        #expect(ports.map(\.port) == [5173, 7000, 9222])
        #expect(ports[0].addresses == ["127.0.0.1", "[::1]"])
        #expect(ports[0].isExposed == false)
        #expect(ports[1].addresses == ["*"])
        #expect(ports[1].isExposed == true)
        #expect(ports[2].processName == "Google Chrome Helper")
    }

    @Test func enrichesPortsWithProcessDetails() async throws {
        let runner = FakeToolRunner([
            PortScanner.listArguments: output(listing),
            ["-a", "-p", "739,4211,4300", "-d", "cwd", "-F", "pn"]: output("p739\nfcwd\nn/\np4211\nfcwd\nn/Users/me/Work/web\n"),
            ["-ww", "-o", "pid=", "-o", "uid=", "-o", "comm=", "-p", "739,4211,4300"]: output("""
              739   501 /System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter
             4211   501 /opt/homebrew/bin/node
             4300   501 /Applications/Google Chrome.app/Contents/Frameworks/Helper
            """),
            ["-ww", "-o", "pid=", "-o", "command=", "-p", "739,4211,4300"]: output(" 4211 node /Users/me/Work/web/node_modules/.bin/vite --port 5173\n"),
        ])

        let ports = try await PortScanner(runner: runner).listeningPorts()
        let home = URL(fileURLWithPath: "/Users/me")
        let vite = try #require(ports.first { $0.port == 5173 })
        let airPlay = try #require(ports.first { $0.port == 7000 })
        let chrome = try #require(ports.first { $0.port == 9222 })

        #expect(vite.userID == 501)
        #expect(vite.commandLine == "node /Users/me/Work/web/node_modules/.bin/vite --port 5173")
        #expect(vite.projectURL(homeDirectory: home)?.lastPathComponent == "web")
        #expect(airPlay.projectURL(homeDirectory: home) == nil)
        #expect(airPlay.isSystemProcess && airPlay.isAirPlayReceiver)
        #expect(chrome.executablePath == "/Applications/Google Chrome.app/Contents/Frameworks/Helper")
        #expect(chrome.workingDirectory == nil)
    }

    @Test func noListenersIsAnEmptyListNotAnError() async throws {
        let runner = FakeToolRunner([PortScanner.listArguments: output("", exitCode: 1)])
        #expect(try await PortScanner(runner: runner).listeningPorts().isEmpty)
        #expect(runner.invocations.count == 1)
    }
}

@Suite struct ProcessTerminatorTests {
    private final class SignalLog: @unchecked Sendable {
        let lock = NSLock()
        var signals: [(pid_t, Int32)] = []
        var result: Int32 = 0
    }

    private func terminator(_ log: SignalLog) -> ProcessTerminator {
        ProcessTerminator(currentProcessID: 999, currentUserID: 501) { pid, signal in
            log.lock.withLock {
                log.signals.append((pid, signal))
                return log.result
            }
        }
    }

    private func port(pid: pid_t = 4211, name: String = "node", port: Int = 3000, userID: uid_t = 501, path: String = "/opt/homebrew/bin/node") -> ListeningPort {
        ListeningPort(port: port, pid: pid, processName: name, addresses: ["127.0.0.1"], userID: userID, executablePath: path)
    }

    @Test func sendsTermThenKillWhenForced() throws {
        let log = SignalLog()
        try terminator(log).terminate(port())
        try terminator(log).terminate(port(), force: true)
        #expect(log.signals.map(\.1) == [SIGTERM, SIGKILL])
        #expect(log.signals.allSatisfy { $0.0 == 4211 })
    }

    @Test func refusesProtectedProcessesWithoutSignalling() {
        let log = SignalLog()
        let refused = [
            port(pid: 1, name: "launchd"),
            port(pid: 999, name: "ApolloKit"),
            port(name: "ControlCenter", port: 5000, path: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter"),
            port(name: "rapportd", path: "/usr/libexec/rapportd"),
            port(name: "postgres", userID: 0),
        ]
        for item in refused {
            #expect(throws: ProcessTerminator.Failure.self) { try terminator(log).terminate(item) }
        }
        #expect(log.signals.isEmpty)
    }

    @Test func alreadyExitedProcessCountsAsStopped() throws {
        let log = SignalLog()
        log.result = ESRCH
        try terminator(log).terminate(port())
        #expect(terminator(log).isRunning(4211) == false)

        log.result = EPERM
        #expect(throws: ProcessTerminator.Failure.notPermitted("node")) { try terminator(log).terminate(port()) }
    }
}
