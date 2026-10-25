import Foundation

public enum DeletionMode: String, Sendable, CaseIterable, Identifiable {
    case moveToTrash
    case deletePermanently

    public var id: String { rawValue }
}

public struct CleanupFailure: Sendable, Identifiable {
    public var id: String { item.id }
    public let item: CleanupItem
    public let reason: String
}

public struct CleanupOutcome: Sendable {
    public var removed: [CleanupItem] = []
    /// Items that no longer existed at clean time.
    public var missing: [CleanupItem] = []
    public var failures: [CleanupFailure] = []

    public var reclaimedBytes: Int64 { removed.reduce(0) { $0 + $1.sizeInBytes } }
}

public struct Cleaner: Sendable {
    public let policy: SafetyPolicy
    public let runner: any ToolRunner
    /// Checks right before removal that no running process has files open in an item.
    /// `nil` skips the check.
    public let fileUsage: FileUsageMonitor?

    public init(policy: SafetyPolicy, runner: any ToolRunner = ProcessToolRunner(), fileUsage: FileUsageMonitor? = nil) {
        self.policy = policy
        self.runner = runner
        self.fileUsage = fileUsage
    }

    public func clean(
        _ items: [CleanupItem],
        mode: DeletionMode,
        progress: @escaping @Sendable (_ completed: Int, _ total: Int) -> Void = { _, _ in }
    ) async -> CleanupOutcome {
        var outcome = CleanupOutcome()
        let inUse = await processesUsing(items)
        for (index, item) in items.enumerated() {
            if Task.isCancelled { break }
            if let path = item.fileURL?.path, let processes = inUse[path] {
                // Removing files under a running tool can leave its cache half-written or break the tool mid-run.
                outcome.failures.append(CleanupFailure(
                    item: item,
                    reason: "In use by \(processes.joined(separator: ", ")). Quit it and try again."
                ))
                progress(index + 1, items.count)
                continue
            }
            do {
                if try await remove(item, mode: mode) {
                    outcome.removed.append(item)
                } else {
                    outcome.missing.append(item)
                }
            } catch {
                outcome.failures.append(CleanupFailure(item: item, reason: error.localizedDescription))
            }
            progress(index + 1, items.count)
        }
        return outcome
    }

    /// One snapshot for the whole batch. When `lsof` itself fails the check is skipped: the items were
    /// picked by the user, and a missing safeguard should not block every cleanup.
    private func processesUsing(_ items: [CleanupItem]) async -> [String: [String]] {
        let urls = items.compactMap(\.fileURL)
        guard let fileUsage, !urls.isEmpty, let snapshot = try? await fileUsage.snapshot() else { return [:] }
        return snapshot.processes(using: urls)
    }

    /// Returns `false` when the item no longer exists.
    func remove(_ item: CleanupItem, mode: DeletionMode) async throws -> Bool {
        switch item.action {
        case .removeItem(let url):
            return try removeFileItem(at: url, mode: item.rule.alwaysDeletePermanently ? .deletePermanently : mode)
        case .runTool(let invocation):
            // Invocations are built by the tool providers from fixed templates, never from user input.
            // Prunes over large Docker caches can take minutes.
            let output = try await runner.run(invocation, timeout: 15 * 60)
            guard output.exitCode == 0 else {
                throw ToolRunnerError.failed(command: invocation.commandLine, exitCode: output.exitCode, message: output.errorText)
            }
            return true
        }
    }

    private func removeFileItem(at url: URL, mode: DeletionMode) throws -> Bool {
        let fileManager = FileManager.default
        guard (try? fileManager.attributesOfItem(atPath: url.path)) != nil else { return false }
        try policy.validate(url)

        switch mode {
        case .moveToTrash:
            try fileManager.trashItem(at: url, resultingItemURL: nil)
        case .deletePermanently:
            do {
                try fileManager.removeItem(at: url)
            } catch where FileErrorClassifier.isPermissionDenied(error) {
                // Some tools (e.g. the Go module cache) intentionally write read-only directories.
                Self.grantOwnerDirectoryAccess(under: url)
                try fileManager.removeItem(at: url)
            }
        }
        return true
    }

    private static func grantOwnerDirectoryAccess(under root: URL) {
        let fileManager = FileManager.default
        func makeAccessible(_ path: String) {
            guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                  attributes[.type] as? FileAttributeType == .typeDirectory,
                  let permissions = attributes[.posixPermissions] as? NSNumber else {
                return
            }
            try? fileManager.setAttributes([.posixPermissions: permissions.intValue | 0o700], ofItemAtPath: path)
        }

        makeAccessible(root.path)
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        while let url = enumerator.nextObject() as? URL {
            makeAccessible(url.path)
        }
    }
}
