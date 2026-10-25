import Foundation

/// One source of space that is not in the user's own files: what macOS Storage settings counts as
/// System Data, and developer disk images that Finder only shows as one opaque file, if at all.
public struct SystemDataEntry: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case simulatorRuntimes
        case simulatorCaches
        case dockerDisk
        case localSnapshots
        case systemAssets
        case softwareUpdate
        case systemLogs
        case sleepImageAndSwap
        case temporaryFiles
    }

    public enum Remedy: Sendable, Hashable {
        /// Removable item by item in Smart Scan.
        case smartScan(RuleGroup)
        /// Can be reclaimed by hand; the text says how.
        case manual(String)
        /// Managed by macOS; nothing to do here.
        case managedByMacOS
    }

    public let kind: Kind
    /// `nil` when the size cannot be measured (APFS snapshots do not report one).
    public let bytes: Int64?
    /// Part of `bytes` that is left over and can go: caches of removed runtimes or earlier macOS versions.
    public let staleBytes: Int64
    /// Snapshot count, or simulator runtimes installed.
    public let count: Int?
    public let locations: [URL]
    /// Some folders could not be read, so the size is a lower bound.
    public let isPartial: Bool

    public var id: Kind { kind }

    public var title: String {
        switch kind {
        case .simulatorRuntimes: "Simulator runtimes"
        case .simulatorCaches: "Simulator system caches"
        case .dockerDisk: "Docker virtual disk"
        case .localSnapshots: "Local snapshots"
        case .systemAssets: "macOS downloaded assets"
        case .softwareUpdate: "Pending macOS update"
        case .systemLogs: "System logs & diagnostics"
        case .sleepImageAndSwap: "Sleep image & swap"
        case .temporaryFiles: "Temporary files"
        }
    }

    public var symbolName: String {
        switch kind {
        case .simulatorRuntimes: "iphone"
        case .simulatorCaches: "square.stack.3d.up"
        case .dockerDisk: "cube.box"
        case .localSnapshots: "clock.arrow.circlepath"
        case .systemAssets: "sparkles"
        case .softwareUpdate: "arrow.down.circle"
        case .systemLogs: "doc.text.magnifyingglass"
        case .sleepImageAndSwap: "memorychip"
        case .temporaryFiles: "clock.badge.xmark"
        }
    }

    public var detail: String {
        switch kind {
        case .simulatorRuntimes:
            "iOS, watchOS, tvOS and visionOS images that Xcode downloads to run simulators, several GB each."
        case .simulatorCaches:
            "Shared caches built for each simulator runtime and each macOS version. They are rebuilt the next time a simulator boots."
        case .dockerDisk:
            "The disk of Docker Desktop's virtual machine: every image, container, volume and build cache lives inside this one file."
        case .localSnapshots:
            "APFS snapshots kept by Time Machine and macOS updates. macOS deletes them on its own when space runs low."
        case .systemAssets:
            "Apple Intelligence models, Siri voices, dictionaries, fonts and other downloads that macOS manages."
        case .softwareUpdate:
            "A downloaded macOS update waiting to be installed."
        case .systemLogs:
            "Unified logs and crash diagnostics. macOS rotates them by age and size."
        case .sleepImageAndSwap:
            "Memory saved to disk for hibernation and swap. Swap shrinks after a restart."
        case .temporaryFiles:
            "Per-user temporary files and caches of macOS services. macOS clears old ones on its own, mostly at restart."
        }
    }

    public var remedy: Remedy {
        switch kind {
        case .simulatorRuntimes: .smartScan(.xcode)
        case .dockerDisk: .smartScan(.docker)
        case .simulatorCaches:
            staleBytes > 0
                ? .manual("Caches for removed runtimes or earlier macOS versions are left over. Removing them needs an administrator: sudo rm -rf on the folders marked stale. Removing runtimes in Smart Scan stops new caches being built for them.")
                : .manual("Removing unused runtimes in Smart Scan stops caches being built for them.")
        case .localSnapshots:
            .manual("To remove them now, run sudo tmutil deletelocalsnapshots / in Terminal.")
        case .systemAssets:
            .manual("Turning off Apple Intelligence in System Settings removes its models.")
        case .softwareUpdate:
            .manual("Installing the update in System Settings › General › Software Update removes the download.")
        case .systemLogs, .sleepImageAndSwap, .temporaryFiles:
            .managedByMacOS
        }
    }
}

/// Measures the `SystemDataEntry` sources. Folders owned by root are mostly readable; what is not
/// makes the entry partial rather than failing it.
public struct SystemDataScanner: Sendable {
    public let runner: any ToolRunner
    public let homeDirectory: URL
    /// `/` outside tests.
    public let fileSystemRoot: URL
    /// The user's folder in `/var/folders`, the parent of `DARWIN_USER_TEMP_DIR`.
    public let userTemporaryDirectory: URL?
    /// Build of the running macOS (`kern.osversion`), used to spot simulator caches of earlier versions.
    public let hostBuild: String?

    private let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
    private let tmutil = URL(fileURLWithPath: "/usr/bin/tmutil")

    public init(
        runner: any ToolRunner = ProcessToolRunner(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileSystemRoot: URL = URL(fileURLWithPath: "/"),
        userTemporaryDirectory: URL? = Self.currentUserTemporaryDirectory(),
        hostBuild: String? = Self.currentHostBuild()
    ) {
        self.runner = runner
        self.homeDirectory = homeDirectory
        self.fileSystemRoot = fileSystemRoot
        self.userTemporaryDirectory = userTemporaryDirectory
        self.hostBuild = hostBuild
    }

    /// Entries are reported through `found` as they finish, since the large folders take several seconds.
    /// Sources that do not exist on this Mac are left out.
    public func scan(found: @escaping @Sendable (SystemDataEntry) -> Void = { _ in }) async -> [SystemDataEntry] {
        let scanner = self
        // Both simulator entries need the runtime list; one simctl call serves them.
        let runtimes = Task { await scanner.simulatorRuntimes() }
        return await withTaskGroup(of: SystemDataEntry?.self) { group in
            for kind in SystemDataEntry.Kind.allCases {
                group.addTask {
                    guard !Task.isCancelled, let entry = await scanner.measure(kind, runtimes: runtimes) else { return nil }
                    found(entry)
                    return entry
                }
            }
            var entries: [SystemDataEntry] = []
            for await entry in group {
                if let entry { entries.append(entry) }
            }
            return entries.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
        }
    }

    private func path(_ systemPath: String) -> URL {
        fileSystemRoot.appendingPathComponent(systemPath)
    }

    private func measure(_ kind: SystemDataEntry.Kind, runtimes runtimesTask: Task<[Runtime], Never>) async -> SystemDataEntry? {
        switch kind {
        case .simulatorRuntimes:
            let runtimes = await runtimesTask.value
            guard !runtimes.isEmpty else { return nil }
            return SystemDataEntry(
                kind: kind, bytes: runtimes.reduce(0) { $0 + ($1.sizeBytes ?? 0) }, staleBytes: 0,
                count: runtimes.count, locations: [], isPartial: false
            )
        case .simulatorCaches:
            return simulatorCaches(installed: Set(await runtimesTask.value.compactMap(\.cacheFolderName)))
        case .dockerDisk:
            return folders(kind, [homeDirectory.appendingPathComponent("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw")])
        case .localSnapshots:
            let count = await localSnapshotCount()
            guard count > 0 else { return nil }
            return SystemDataEntry(kind: kind, bytes: nil, staleBytes: 0, count: count, locations: [], isPartial: false)
        case .systemAssets:
            return folders(kind, [path("System/Library/AssetsV2")])
        case .softwareUpdate:
            return folders(kind, [path("Library/Updates")])
        case .systemLogs:
            return folders(kind, [
                path("private/var/db/diagnostics"), path("private/var/db/uuidtext"), path("private/var/log"), path("Library/Logs"),
            ])
        case .sleepImageAndSwap:
            return folders(kind, [path("private/var/vm")])
        case .temporaryFiles:
            return userTemporaryDirectory.flatMap { folders(kind, [$0]) }
        }
    }

    private func folders(_ kind: SystemDataEntry.Kind, _ urls: [URL]) -> SystemDataEntry? {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        let measurements = existing.map { DirectorySizer.measure($0) }
        let bytes = measurements.reduce(0) { $0 + $1.allocatedBytes }
        guard bytes > 0 else { return nil }
        return SystemDataEntry(
            kind: kind, bytes: bytes, staleBytes: 0, count: nil, locations: existing,
            isPartial: measurements.contains { $0.unreadableEntryCount > 0 }
        )
    }

    // MARK: - Simulators

    struct Runtime: Decodable {
        let build: String?
        let sizeBytes: Int64?
        let runtimeIdentifier: String?

        /// Cache folders are named `<runtimeIdentifier>.<build>`.
        var cacheFolderName: String? {
            guard let runtimeIdentifier, let build else { return nil }
            return "\(runtimeIdentifier).\(build)"
        }
    }

    private func simulatorRuntimes() async -> [Runtime] {
        let invocation = ToolInvocation(executable: xcrun, arguments: ["simctl", "runtime", "list", "--json"])
        guard FileManager.default.isExecutableFile(atPath: xcrun.path),
              let output = try? await runner.run(invocation, timeout: 30), output.exitCode == 0,
              let runtimes = try? JSONDecoder().decode([String: Runtime].self, from: output.standardOutput) else {
            return []
        }
        return Array(runtimes.values)
    }

    /// `Caches/dyld/<macOS build>/<runtime>.<build>`: one set per macOS version, one folder per runtime.
    private func simulatorCaches(installed: Set<String>) -> SystemDataEntry? {
        let root = path("Library/Developer/CoreSimulator/Caches/dyld")
        let fileManager = FileManager.default
        guard let hostBuilds = try? fileManager.contentsOfDirectory(atPath: root.path) else { return nil }

        var bytes: Int64 = 0
        var staleBytes: Int64 = 0
        var isPartial = false
        var staleFolders: [URL] = []
        for build in hostBuilds where !build.hasPrefix(".") {
            let buildFolder = root.appendingPathComponent(build)
            let runtimes = (try? fileManager.contentsOfDirectory(atPath: buildFolder.path)) ?? []
            for runtime in runtimes where !runtime.hasPrefix(".") {
                let folder = buildFolder.appendingPathComponent(runtime)
                let measurement = DirectorySizer.measure(folder)
                bytes += measurement.allocatedBytes
                isPartial = isPartial || measurement.unreadableEntryCount > 0
                // Without a runtime list only the macOS version can be judged.
                let isOldMacOS = hostBuild.map { build != $0 } ?? false
                let isRemovedRuntime = !installed.isEmpty && runtime.hasPrefix("com.apple.") && !installed.contains(runtime)
                if measurement.allocatedBytes > 0, isOldMacOS || isRemovedRuntime {
                    staleBytes += measurement.allocatedBytes
                    staleFolders.append(folder)
                }
            }
        }
        guard bytes > 0 else { return nil }
        return SystemDataEntry(
            kind: .simulatorCaches, bytes: bytes, staleBytes: staleBytes, count: nil,
            locations: staleFolders.isEmpty ? [root] : staleFolders, isPartial: isPartial
        )
    }

    // MARK: - Snapshots

    private func localSnapshotCount() async -> Int {
        let invocation = ToolInvocation(executable: tmutil, arguments: ["listlocalsnapshots", "/"])
        guard let output = try? await runner.run(invocation, timeout: 30), output.exitCode == 0 else { return 0 }
        return Self.snapshotCount(in: String(decoding: output.standardOutput, as: UTF8.self))
    }

    /// The first line is a `Snapshots for disk /:` header; each snapshot is one `com.apple.…` line.
    static func snapshotCount(in text: String) -> Int {
        text.split(separator: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("com.apple.") }.count
    }

    // MARK: - Host

    public static func currentHostBuild() -> String? {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return nil }
        return Self.string(from: buffer)
    }

    public static func currentUserTemporaryDirectory() -> URL? {
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, length) > 0 else { return nil }
        // `…/T/` holds temporary files; its parent also has the `C` caches of macOS services.
        return URL(fileURLWithPath: Self.string(from: buffer), isDirectory: true).deletingLastPathComponent()
    }

    private static func string(from buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
