import Foundation
import Testing
@testable import ApolloKitCore

@Suite struct ProjectActivityTests {
    private func age(_ url: URL, days: Double) throws {
        let date = Date.now.addingTimeInterval(-days * 24 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    @Test func artifactsOfRecentlyChangedProjectsAreMarkedActive() async throws {
        let tree = try TemporaryTree()
        try age(tree.file("Workspace/old/package.json"), days: 200)
        // Installs and builds rewrite artifacts; that must not make the project look active.
        try tree.file("Workspace/old/node_modules/left-pad/index.js")
        try age(tree.file("Workspace/mono/.git/HEAD"), days: 200)
        try tree.file("Workspace/mono/packages/a/package.json")
        try tree.file("Workspace/mono/packages/a/node_modules/x/index.js")
        try age(tree.file("Workspace/mono/packages/b/package.json"), days: 200)
        try tree.file("Workspace/mono/packages/b/node_modules/y/index.js")

        let report = try await DiskScanner(
            homeDirectory: tree.root,
            tools: ToolEnvironment(runner: FakeToolRunner([:]), xcrun: nil, docker: nil),
            activeProjectWindow: 30 * 24 * 60 * 60
        ).scan(enabledRuleIDs: ["project.nodeModules"], projectRoots: [tree.url("Workspace")])

        let projects = Dictionary(uniqueKeysWithValues: report.projects.map { ($0.name, $0) })
        #expect(projects.keys.sorted() == ["mono", "old"])
        #expect(projects["mono"]?.itemIDs.count == 2)
        let oldActivity = try #require(projects["old"]?.lastActivity)
        #expect(oldActivity < Date.now.addingTimeInterval(-100 * 24 * 60 * 60))

        // Scanned paths keep /private while `tree.url` standardizes it away, so match on the part under the root.
        let itemsByPath = Dictionary(uniqueKeysWithValues: report.items.map { (String($0.id.split(separator: "/Workspace/").last!), $0) })
        #expect(itemsByPath["old/node_modules"]?.concerns == [])
        for package in ["a", "b"] {
            let item = try #require(itemsByPath["mono/packages/\(package)/node_modules"])
            #expect(item.risk == .caution)
            guard case .activeProject = item.concerns.first else {
                Issue.record("\(package) should be marked as part of an active project")
                continue
            }
        }
    }

    @Test func projectRootStopsAtTheSearchRootAndNeverClaimsTheHomeFolder() throws {
        let tree = try TemporaryTree()
        try tree.directory(".git")
        try tree.file("Workspace/.git/HEAD")
        try tree.file("Code/tool/package.json")
        let inspector = ProjectActivityInspector(
            searchRoots: [tree.url("Workspace"), tree.url("Code")],
            homeDirectory: tree.root
        )

        #expect(inspector.projectRoot(for: tree.url("Workspace/site/node_modules")) == tree.url("Workspace"))
        #expect(inspector.projectRoot(for: tree.url("Code/tool/node_modules")) == tree.url("Code/tool"))
    }
}

@Suite struct ProjectRootDetectorTests {
    @Test func findsConventionalFoldersAndAnyFolderHoldingRepositories() throws {
        let tree = try TemporaryTree()
        try tree.directory("Workspace")
        try tree.directory("Cyberk/client/app/.git")
        try tree.directory("Documents/GitHub/tool/.git")
        try tree.directory("Documents/Taxes/2025")
        try tree.directory("Downloads/sample/.git")
        try tree.directory("Notes/drafts")
        try tree.directory("Deep/a/b/c/.git")
        try tree.directory(".hidden/repo/.git")

        let detected = ProjectRootDetector(homeDirectory: tree.root).detect().map(\.standardizedFileURL.path)

        #expect(detected == [tree.url("Cyberk"), tree.url("Documents/GitHub"), tree.url("Workspace")].map(\.path))
    }
}

@Suite struct ProjectRootListTests {
    private let workspace = URL(fileURLWithPath: "/Users/me/Workspace")
    private let cyberk = URL(fileURLWithPath: "/Users/me/Cyberk")
    private let external = URL(fileURLWithPath: "/Volumes/Code")

    @Test func userEditsSurviveDetectionFindingNewFolders() {
        var list = ProjectRootList(detected: [workspace])
        list.add([external])
        list.remove([workspace])
        list.updateDetected([workspace, cyberk])

        #expect(list.roots == [external, cyberk].sorted { $0.path < $1.path })

        list.add([workspace])
        #expect(list.removed.isEmpty)
        #expect(list.added == [external])
        #expect(list.roots.count == 3)
    }

    @Test func migratesASavedListIntoAdditionsAndRemovals() {
        let list = ProjectRootList(migratingSavedRoots: [workspace, external], detected: [workspace, cyberk])

        #expect(list.added == [external])
        #expect(list.removed == [cyberk])
        #expect(list.roots == [external, workspace].sorted { $0.path < $1.path })
    }
}
