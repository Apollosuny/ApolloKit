import Foundation
import Testing
@testable import ApolloKitCore

@Suite struct LaunchItemTests {
    private let launchctl = URL(fileURLWithPath: "/bin/launchctl")

    private func writePlist(_ tree: TemporaryTree, _ path: String, _ plist: [String: Any]) throws {
        let url = tree.url(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
    }

    private func manager(_ tree: TemporaryTree, runner: FakeToolRunner = FakeToolRunner([:])) -> LaunchItemManager {
        LaunchItemManager(homeDirectory: tree.url("home"), systemLibrary: tree.url("Library"), runner: runner, userID: 501)
    }

    @Test func readsJobsAndFlagsMissingPrograms() throws {
        let tree = try TemporaryTree()
        let program = try tree.file("Applications/Docker.app/Contents/MacOS/helper")
        try writePlist(tree, "home/Library/LaunchAgents/com.docker.helper.plist", [
            "Label": "com.docker.helper", "ProgramArguments": [program.path, "--start"], "RunAtLoad": true,
        ])
        try writePlist(tree, "Library/LaunchDaemons/us.zoom.ZoomDaemon.plist", [
            "Label": "us.zoom.ZoomDaemon", "Program": tree.url("Applications/zoom.us.app/Contents/Daemon").path,
            "KeepAlive": ["SuccessfulExit": false],
        ])
        try writePlist(tree, "home/Library/LaunchAgents/homebrew.node.plist", ["Label": "homebrew.node", "ProgramArguments": ["node", "server.js"]])
        try tree.file("home/Library/LaunchAgents/notes.txt")

        let items = manager(tree).items()
        let byLabel = Dictionary(uniqueKeysWithValues: items.map { ($0.label, $0) })

        #expect(items.map(\.label) == ["com.docker.helper", "homebrew.node", "us.zoom.ZoomDaemon"])
        #expect(byLabel["com.docker.helper"]?.isOrphaned == false)
        #expect(byLabel["com.docker.helper"]?.owningAppURL?.lastPathComponent == "Docker.app")
        #expect(byLabel["com.docker.helper"]?.runsAtLoad == true)
        #expect(byLabel["homebrew.node"]?.isOrphaned == false)
        #expect(byLabel["us.zoom.ZoomDaemon"]?.isOrphaned == true)
        #expect(byLabel["us.zoom.ZoomDaemon"]?.keepsAlive == true)
        #expect(byLabel["us.zoom.ZoomDaemon"]?.isUserEditable == false)
    }

    @Test func parsesLaunchctlState() async throws {
        let runner = FakeToolRunner([
            ["list"]: ToolOutput(exitCode: 0, standardOutput: Data("PID\tStatus\tLabel\n412\t0\tcom.docker.helper\n-\t0\thomebrew.node\n".utf8)),
            ["print-disabled", "gui/501"]: ToolOutput(exitCode: 0, standardOutput: Data("""
            \tdisabled services = {
            \t\t"com.google.keystone.agent" => disabled
            \t\t"homebrew.node" => enabled
            \t\t"com.legacy.job" => true
            \t}
            """.utf8)),
        ])
        let states = await manager(try TemporaryTree(), runner: runner).states()
        #expect(states.loadedLabels == ["com.docker.helper", "homebrew.node"])
        #expect(states.runningLabels == ["com.docker.helper"])
        #expect(states.disabledLabels == ["com.google.keystone.agent", "com.legacy.job"])
    }

    @Test func disablesPersistentlyThenUnloads() async throws {
        let tree = try TemporaryTree()
        try writePlist(tree, "home/Library/LaunchAgents/com.example.agent.plist", ["Label": "com.example.agent", "Program": "/bin/true"])
        let runner = FakeToolRunner([
            ["disable", "gui/501/com.example.agent"]: ToolOutput(exitCode: 0),
            ["bootout", "gui/501/com.example.agent"]: ToolOutput(exitCode: 0),
        ])
        let manager = manager(tree, runner: runner)
        try await manager.disable(try #require(manager.items().first))

        #expect(runner.invocations.map(\.arguments) == [["disable", "gui/501/com.example.agent"], ["bootout", "gui/501/com.example.agent"]])
    }

    @Test func refusesToChangeJobsInstalledForAllUsers() async throws {
        let tree = try TemporaryTree()
        try writePlist(tree, "Library/LaunchAgents/com.vendor.updater.plist", ["Label": "com.vendor.updater", "Program": "/bin/true"])
        let runner = FakeToolRunner([:])
        let manager = manager(tree, runner: runner)

        await #expect(throws: ToolRunnerError.self) { try await manager.disable(try #require(manager.items().first)) }
        #expect(runner.invocations.isEmpty)
    }
}
