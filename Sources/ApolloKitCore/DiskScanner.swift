import Foundation

public struct DiskScanner: Sendable {
    public let homeDirectory: URL
    public let catalog: [CleanupRule]
    public let maximumConcurrentMeasurements: Int
    public let tools: ToolEnvironment

    private static let ignoredEntryNames: Set<String> = [".DS_Store", ".localized"]

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        catalog: [CleanupRule] = RuleCatalog.all,
        maximumConcurrentMeasurements: Int = max(2, ProcessInfo.processInfo.activeProcessorCount),
        tools: ToolEnvironment = .system
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.catalog = catalog
        self.maximumConcurrentMeasurements = maximumConcurrentMeasurements
        self.tools = tools
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

        var seenPaths = Set<String>()
        var candidates: [ScanCandidate] = []
        for candidate in located.flatMap(\.candidates) where seenPaths.insert(candidate.url.standardizedFileURL.path).inserted {
            candidates.append(candidate)
        }

        let (fileItems, measurementIssues) = try await measure(candidates, progress: progress)
        let tool = await toolResult
        try Task.checkCancellation()
        return ScanReport(
            items: (fileItems + tool.items).sorted { $0.sizeInBytes > $1.sizeInBytes },
            issues: located.flatMap(\.issues) + measurementIssues + tool.issues,
            startedAt: startedAt,
            finishedAt: Date()
        )
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
                        result.candidates.append(ScanCandidate(url: url, rule: rule))
                    }
                case .childrenOf(let path):
                    let parent = resolve(path)
                    guard (try? fileManager.attributesOfItem(atPath: parent.path)) != nil else { continue }
                    do {
                        let children = try fileManager.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
                        for child in children
                        where !Self.ignoredEntryNames.contains(child.lastPathComponent) && !isClaimed(child, claimed: claimed) {
                            result.candidates.append(ScanCandidate(url: child.standardizedFileURL, rule: rule))
                        }
                    } catch {
                        result.issues.append(ScanIssue(url: parent, error: error))
                    }
                case .projectArtifact, .tool:
                    continue
                }
            }
        }
        return result
    }

    // MARK: - Measurement

    private struct Measured: Sendable {
        let candidate: ScanCandidate
        let measurement: SizeMeasurement
        let lastModified: Date?
    }

    private static func measure(_ candidate: ScanCandidate) -> Measured {
        let modified = try? candidate.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return Measured(candidate: candidate, measurement: DirectorySizer.measure(candidate.url), lastModified: modified)
    }

    private func measure(
        _ candidates: [ScanCandidate],
        progress: @escaping @Sendable (ScanProgress) -> Void
    ) async throws -> ([CleanupItem], [ScanIssue]) {
        try await withThrowingTaskGroup(of: Measured.self) { group in
            var pending = candidates.makeIterator()
            for _ in 0..<maximumConcurrentMeasurements {
                guard let next = pending.next() else { break }
                group.addTask { try Task.checkCancellation(); return Self.measure(next) }
            }

            var items: [CleanupItem] = []
            var issues: [ScanIssue] = []
            var completed = 0
            while let measured = try await group.next() {
                completed += 1
                progress(.measuring(completed: completed, total: candidates.count))

                let measurement = measured.measurement
                if measurement.unreadableEntryCount > 0 {
                    issues.append(ScanIssue(
                        url: measured.candidate.url,
                        message: "\(measurement.unreadableEntryCount) entries could not be read; size may be underestimated.",
                        isPermissionDenied: true
                    ))
                }
                if measurement.allocatedBytes > 0 {
                    items.append(CleanupItem(
                        url: measured.candidate.url,
                        rule: measured.candidate.rule,
                        sizeInBytes: measurement.allocatedBytes,
                        lastModified: measured.lastModified
                    ))
                }

                if let next = pending.next() {
                    group.addTask { try Task.checkCancellation(); return Self.measure(next) }
                }
            }
            return (items, issues)
        }
    }
}
