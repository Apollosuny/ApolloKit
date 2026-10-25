import Foundation

public struct DiskScanner: Sendable {
    public let homeDirectory: URL
    public let catalog: [CleanupRule]
    public let maximumConcurrentMeasurements: Int
    public let tools: ToolEnvironment
    /// Folders searched for installed apps when deciding whether app data is a leftover.
    public let applicationDirectories: [URL]
    public let largeFileSearch: LargeFileSearch
    /// Marks items that running processes have files open in, so they are not pre-selected. `nil` skips it.
    public let fileUsage: FileUsageMonitor?
    /// Build artifacts of projects changed within this interval are marked as active, so they are not pre-selected.
    /// `nil` still reports projects but marks none.
    public let activeProjectWindow: TimeInterval?

    private static let ignoredEntryNames: Set<String> = [".DS_Store", ".localized"]

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        catalog: [CleanupRule] = RuleCatalog.all,
        maximumConcurrentMeasurements: Int = max(2, ProcessInfo.processInfo.activeProcessorCount),
        tools: ToolEnvironment = .system,
        applicationDirectories: [URL]? = nil,
        largeFileSearch: LargeFileSearch = LargeFileSearch(),
        fileUsage: FileUsageMonitor? = nil,
        activeProjectWindow: TimeInterval? = nil
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.catalog = catalog
        self.maximumConcurrentMeasurements = maximumConcurrentMeasurements
        self.tools = tools
        self.largeFileSearch = largeFileSearch
        self.fileUsage = fileUsage
        self.activeProjectWindow = activeProjectWindow
        self.applicationDirectories = applicationDirectories ?? [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Setapp"),
            homeDirectory.appendingPathComponent("Applications"),
        ]
    }

    public func scan(
        enabledRuleIDs: Set<String>,
        projectRoots: [URL],
        progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }
    ) async throws -> ScanReport {
        let startedAt = Date()
        let enabledRules = catalog.filter { enabledRuleIDs.contains($0.id) }

        let toolBindings = enabledRules.flatMap { rule in
            rule.locators.compactMap(\.toolSource).map { ToolBinding(source: $0, rule: rule) }
        }
        let toolScanner = ToolScanner(tools: tools)
        async let toolResult = toolBindings.isEmpty
            ? ToolLocateResult()
            : toolScanner.scan(toolBindings, progress: progress)

        var located = [locateFixedPathCandidates(rules: enabledRules, progress: progress)]
        try Task.checkCancellation()

        let bindings = enabledRules.flatMap { rule in
            rule.locators.compactMap(\.artifactPattern).map { PatternBinding(pattern: $0, rule: rule) }
        }
        if !bindings.isEmpty, !projectRoots.isEmpty {
            let finder = ProjectArtifactFinder(
                bindings: bindings,
                excludedDirectories: [resolve("Library"), resolve(".Trash")]
            )
            located += await withTaskGroup(of: LocateResult.self) { group in
                for root in projectRoots {
                    group.addTask { finder.find(in: root, progress: progress) }
                }
                var results: [LocateResult] = []
                for await result in group { results.append(result) }
                return results
            }
        }
        try Task.checkCancellation()

        let largeFileBindings = enabledRules.flatMap { rule in
            rule.locators.compactMap(\.largeFileExtensions).map { LargeFileBinding(extensions: $0, rule: rule) }
        }
        if !largeFileBindings.isEmpty {
            let finder = LargeFileFinder(
                bindings: largeFileBindings,
                claimedExtensions: Set(catalog.flatMap(\.locators).compactMap(\.largeFileExtensions).joined()),
                minimumBytes: largeFileSearch.minimumBytes,
                excludedDirectories: projectRoots
            )
            let roots = largeFileSearch.homeRelativeRoots.map(resolve)
            located += await withTaskGroup(of: LocateResult.self) { group in
                for root in roots {
                    group.addTask { finder.find(in: root, progress: progress) }
                }
                var results: [LocateResult] = []
                for await result in group { results.append(result) }
                return results
            }
        }
        try Task.checkCancellation()

        var seenPaths = Set<String>()
        var candidates: [ScanCandidate] = []
        for candidate in located.flatMap(\.candidates) where seenPaths.insert(candidate.url.standardizedFileURL.path).inserted {
            candidates.append(candidate)
        }

        let (measuredItems, measurementIssues) = try await measure(candidates, progress: progress)
        progress(.finishing(step: "Checking which projects are active…"))
        let projects = await summarizeProjects(of: measuredItems, projectRoots: projectRoots)
        progress(.finishing(step: "Checking which items are in use…"))
        let fileItems = await markingItemsInUse(markingActiveProjects(measuredItems, projects: projects))
        progress(.finishing(step: "Waiting for Docker and simulators…"))
        let tool = await toolResult
        try Task.checkCancellation()
        return ScanReport(
            items: (fileItems + tool.items).sorted { $0.sizeInBytes > $1.sizeInBytes },
            issues: located.flatMap(\.issues) + measurementIssues + tool.issues,
            projects: projects,
            startedAt: startedAt,
            finishedAt: Date()
        )
    }

    /// Best effort: without a snapshot the items are reported unmarked, and the cleaner checks again before removing.
    private func markingItemsInUse(_ items: [CleanupItem]) async -> [CleanupItem] {
        guard let fileUsage, let snapshot = try? await fileUsage.snapshot() else { return items }
        let inUse = snapshot.processes(using: items.compactMap(\.fileURL))
        guard !inUse.isEmpty else { return items }
        return items.map { item in
            guard let path = item.fileURL?.path, let processes = inUse[path] else { return item }
            var marked = item
            marked.concerns.append(.inUse(processes: processes))
            return marked
        }
    }

    // MARK: - Projects

    private func summarizeProjects(of items: [CleanupItem], projectRoots: [URL]) async -> [ProjectSummary] {
        let inspector = ProjectActivityInspector(searchRoots: projectRoots, homeDirectory: homeDirectory)
        let artifacts = items.filter { $0.rule.group == .projectArtifacts && $0.fileURL != nil }
        let byRoot = Dictionary(grouping: artifacts) { inspector.projectRoot(for: $0.fileURL!) }
        let artifactPaths = Set(artifacts.compactMap { $0.fileURL?.standardizedFileURL.path })

        return await withTaskGroup(of: ProjectSummary.self) { group in
            var pending = byRoot.makeIterator()
            func addNext() {
                guard let (root, items) = pending.next() else { return }
                group.addTask {
                    ProjectSummary(
                        root: root,
                        lastActivity: Task.isCancelled ? nil : inspector.lastActivity(of: root, ignoring: artifactPaths),
                        itemIDs: items.map(\.id)
                    )
                }
            }
            for _ in 0..<maximumConcurrentMeasurements { addNext() }

            var projects: [ProjectSummary] = []
            while let project = await group.next() {
                projects.append(project)
                addNext()
            }
            return projects.sorted { $0.root.path < $1.root.path }
        }
    }

    private func markingActiveProjects(_ items: [CleanupItem], projects: [ProjectSummary]) -> [CleanupItem] {
        guard let activeProjectWindow else { return items }
        let cutoff = Date.now.addingTimeInterval(-activeProjectWindow)
        var activityByItemID: [CleanupItem.ID: Date] = [:]
        for project in projects {
            guard let lastActivity = project.lastActivity, lastActivity >= cutoff else { continue }
            for id in project.itemIDs { activityByItemID[id] = lastActivity }
        }
        return items.map { item in
            guard let lastActivity = activityByItemID[item.id] else { return item }
            var marked = item
            marked.concerns.append(.activeProject(lastActivity: lastActivity))
            return marked
        }
    }

    // MARK: - Fixed paths

    private func resolve(_ homeRelativePath: String) -> URL {
        homeDirectory.appendingPathComponent(homeRelativePath).standardizedFileURL
    }

    /// Paths owned by specific rules across the whole catalog (enabled or not), so a disabled
    /// specific rule never lets its directory leak into a generic `childrenOf` rule.
    private var claimedPaths: Set<String> {
        Set(catalog.flatMap(\.locators).compactMap(\.homeRelativePath).map { resolve($0).path })
    }

    private func isClaimed(_ url: URL, claimed: Set<String>) -> Bool {
        let path = url.standardizedFileURL.path
        return claimed.contains(path) || claimed.contains { $0.hasPrefix(path + "/") }
    }

    private func locateFixedPathCandidates(rules: [CleanupRule], progress: @Sendable (ScanProgress) -> Void) -> LocateResult {
        let fileManager = FileManager.default
        let claimed = claimedPaths
        var result = LocateResult()

        for rule in rules {
            progress(.locating(ruleTitle: rule.title))
            for locator in rule.locators {
                switch locator {
                case .directory(let path):
                    let url = resolve(path)
                    if (try? fileManager.attributesOfItem(atPath: url.path)) != nil {
                        result.candidates.append(ScanCandidate(url: url, rule: rule, displayName: Self.displayName(forHomeRelativePath: path)))
                    }
                case .childrenOf(let path, let label):
                    let parent = resolve(path)
                    guard (try? fileManager.attributesOfItem(atPath: parent.path)) != nil else { continue }
                    do {
                        let children = try fileManager.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
                        for child in children
                        where !Self.ignoredEntryNames.contains(child.lastPathComponent) && !isClaimed(child, claimed: claimed) {
                            let name = Self.simulatorDeviceName(in: child) ?? child.lastPathComponent
                            result.candidates.append(ScanCandidate(
                                url: child.standardizedFileURL,
                                rule: rule,
                                displayName: label.map { "\($0) \(name)" } ?? name
                            ))
                        }
                    } catch {
                        result.issues.append(ScanIssue(url: parent, error: error))
                    }
                case .eachChild(let path, let subpaths, let label):
                    for child in directoryChildren(of: resolve(path), into: &result) {
                        for subpath in subpaths {
                            let url = child.appendingPathComponent(subpath).standardizedFileURL
                            guard (try? fileManager.attributesOfItem(atPath: url.path)) != nil else { continue }
                            let name = ([label, child.lastPathComponent] + subpath.split(separator: "/").map(String.init))
                                .joined(separator: " › ")
                            result.candidates.append(ScanCandidate(url: url, rule: rule, displayName: name))
                        }
                    }
                case .toolchainVersions(let manager):
                    let versions = directoryChildren(of: resolve(manager.versionsHomeRelativePath), into: &result)
                    let protected = manager.protectedVersions(
                        installed: versions.map(\.lastPathComponent),
                        homeDirectory: homeDirectory
                    )
                    for version in versions where !protected.contains(version.lastPathComponent) {
                        let globalTools = manager.globalTools(in: version)
                        result.candidates.append(ScanCandidate(
                            url: version.standardizedFileURL,
                            rule: rule,
                            displayName: "\(manager.rawValue) \(version.lastPathComponent)",
                            concerns: globalTools.isEmpty ? [] : [.globalTools(globalTools)]
                        ))
                    }
                case .leftover(let path, let appBundleNames):
                    let url = resolve(path)
                    guard (try? fileManager.attributesOfItem(atPath: url.path)) != nil,
                          !isAnyAppInstalled(appBundleNames) else { continue }
                    let appName = appBundleNames.first.map { ($0 as NSString).deletingPathExtension } ?? "App"
                    result.candidates.append(ScanCandidate(
                        url: url,
                        rule: rule,
                        displayName: "\(appName) (not installed) › \(url.lastPathComponent)"
                    ))
                case .projectArtifact, .tool, .largeFile:
                    continue
                }
            }
        }
        return result
    }

    private static let displayPrefixesToDrop = ["Library/Application Support/", "Library/Caches/", "Library/Developer/", "Library/"]

    /// `Library/Application Support/Notion/Partitions/notion/Cache` → `Notion › Partitions › notion › Cache`
    static func displayName(forHomeRelativePath path: String) -> String {
        let trimmed = displayPrefixesToDrop.first { path.hasPrefix($0) }.map { String(path.dropFirst($0.count)) } ?? path
        return trimmed.split(separator: "/").joined(separator: " › ")
    }

    /// Simulator device folders (including XCTest clones) are named by UDID; `device.plist` holds the readable name.
    static func simulatorDeviceName(in directory: URL) -> String? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("device.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let name = plist["name"] as? String else {
            return nil
        }
        return "\(name) · \(directory.lastPathComponent.prefix(8))"
    }

    /// Non-hidden child directories, ignoring symlinks (e.g. `rustup toolchain link`).
    private func directoryChildren(of parent: URL, into result: inout LocateResult) -> [URL] {
        guard (try? FileManager.default.attributesOfItem(atPath: parent.path)) != nil else { return [] }
        do {
            return try FileManager.default.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ).filter {
                let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return values?.isDirectory == true && values?.isSymbolicLink != true
            }
        } catch {
            result.issues.append(ScanIssue(url: parent, error: error))
            return []
        }
    }

    private func isAnyAppInstalled(_ bundleNames: [String]) -> Bool {
        bundleNames.contains { name in
            applicationDirectories.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent(name).path) }
        }
    }

    // MARK: - Measurement

    private struct Measured: Sendable {
        let candidate: ScanCandidate
        let measurement: SizeMeasurement
        let lastModified: Date?
    }

    private static func measure(_ candidate: ScanCandidate) -> Measured {
        var modified = try? candidate.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if candidate.rule.group == .largeFiles {
            modified = LargeFileFinder.lastUsedDate(of: candidate.url, modified: modified)
        }
        let measurement = DirectorySizer.measure(candidate.url, detectsPrograms: candidate.rule.inspectsForPrograms)
        return Measured(candidate: candidate, measurement: measurement, lastModified: modified)
    }

    private static func progressName(_ candidate: ScanCandidate) -> String {
        candidate.displayName
            ?? "\(candidate.url.deletingLastPathComponent().lastPathComponent)/\(candidate.url.lastPathComponent)"
    }

    /// Large-file bundles are found before their size is known, so the threshold is applied after measuring.
    private func minimumReportedBytes(for rule: CleanupRule) -> Int64 {
        rule.group == .largeFiles ? largeFileSearch.minimumBytes : 1
    }

    private func measure(
        _ candidates: [ScanCandidate],
        progress: @escaping @Sendable (ScanProgress) -> Void
    ) async throws -> ([CleanupItem], [ScanIssue]) {
        try await withThrowingTaskGroup(of: Measured.self) { group in
            var pending = candidates.makeIterator()
            // In start order, so progress names the item that has been measured the longest.
            var running: [ScanCandidate] = []
            func addNext() {
                guard let next = pending.next() else { return }
                running.append(next)
                group.addTask { try Task.checkCancellation(); return Self.measure(next) }
            }
            for _ in 0..<maximumConcurrentMeasurements { addNext() }

            var items: [CleanupItem] = []
            var issues: [ScanIssue] = []
            var completed = 0
            while let measured = try await group.next() {
                completed += 1
                running.removeAll { $0.url == measured.candidate.url }
                addNext()
                progress(.measuring(completed: completed, total: candidates.count, current: running.first.map(Self.progressName)))

                let measurement = measured.measurement
                if measurement.unreadableEntryCount > 0 {
                    issues.append(ScanIssue(
                        url: measured.candidate.url,
                        message: "\(measurement.unreadableEntryCount) entries could not be read; size may be underestimated.",
                        isPermissionDenied: true
                    ))
                }
                if measurement.allocatedBytes >= minimumReportedBytes(for: measured.candidate.rule) {
                    progress(.discovered(group: measured.candidate.rule.group, bytes: measurement.allocatedBytes))
                    items.append(CleanupItem(
                        url: measured.candidate.url,
                        rule: measured.candidate.rule,
                        sizeInBytes: measurement.allocatedBytes,
                        lastModified: measured.lastModified,
                        displayName: measured.candidate.displayName,
                        concerns: measured.candidate.concerns + (measurement.containsPrograms ? [.containsPrograms] : [])
                    ))
                }
            }
            return (items, issues)
        }
    }
}
