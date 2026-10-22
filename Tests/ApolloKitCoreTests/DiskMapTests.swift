import Foundation
import Testing
@testable import ApolloKitCore

@Suite struct DiskMapTests {
    private let scanner = DiskMapScanner(minimumNodeBytes: 50_000, maximumChildren: 3, parallelDepth: 1)

    @Test func measuresFoldersAndSortsLargestFirst() async throws {
        let tree = try TemporaryTree()
        try tree.file("Work/web/node_modules/big.bin", bytes: 400_000)
        try tree.file("Work/web/index.html", bytes: 100_000)
        try tree.file("Movies/clip.mov", bytes: 800_000)
        try tree.file("notes.txt", bytes: 100)

        let root = await scanner.scan(tree.root)

        #expect(root.children.map(\.name) == ["Movies", "Work", "1 smaller items"])
        #expect(root.bytes == root.children.reduce(0) { $0 + $1.bytes })
        let web = try #require(root.node(at: tree.url("Work/web")))
        #expect(web.children.map(\.name) == ["node_modules", "index.html"])
        #expect(web.bytes >= 500_000)
    }

    @Test func mergesEntriesBeyondTheLimit() async throws {
        let tree = try TemporaryTree()
        for index in 0..<5 {
            try tree.file("Downloads/file\(index).bin", bytes: 100_000 * (index + 1))
        }

        let downloads = try #require(await scanner.scan(tree.root).node(at: tree.url("Downloads")))

        #expect(downloads.children.map(\.name) == ["file4.bin", "file3.bin", "file2.bin", "2 smaller items"])
        #expect(downloads.children.last?.isRemovable == false)
        #expect(downloads.bytes == downloads.children.reduce(0) { $0 + $1.bytes })
    }

    @Test func packagesAreOneItemAndSymlinksAreSkipped() async throws {
        let tree = try TemporaryTree()
        try tree.file("Applications/Tool.app/Contents/MacOS/Tool", bytes: 300_000)
        try FileManager.default.createSymbolicLink(at: tree.url("link"), withDestinationURL: tree.url("Applications"))

        let root = await scanner.scan(tree.root)
        let app = try #require(root.node(at: tree.url("Applications"))?.children.first)

        #expect(app.kind == .package)
        #expect(app.children.isEmpty)
        #expect(!root.children.contains { $0.name == "link" })
    }

    @Test func removingUpdatesAncestorSizes() async throws {
        let tree = try TemporaryTree()
        try tree.file("Work/web/node_modules/big.bin", bytes: 400_000)
        try tree.file("Work/web/index.html", bytes: 100_000)
        try tree.file("Movies/clip.mov", bytes: 800_000)

        let root = await scanner.scan(tree.root)
        let modules = try #require(root.node(at: tree.url("Work/web/node_modules")))
        let updated = root.removing([modules.url.path])

        #expect(updated.bytes == root.bytes - modules.bytes)
        #expect(updated.node(at: tree.url("Work"))?.bytes == root.node(at: tree.url("Work"))!.bytes - modules.bytes)
        #expect(updated.node(at: tree.url("Work/web/node_modules")) == nil)
        #expect(updated.path(to: tree.url("Work/web")).map(\.name) == [tree.root.lastPathComponent, "Work", "web"])
    }
}
