import Foundation

public struct SizeMeasurement: Sendable, Equatable {
    public let allocatedBytes: Int64
    public let unreadableEntryCount: Int
}

public enum DirectorySizer {
    private static let entryKeys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
    private static let rootKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
    ]

    /// Sums allocated sizes without following symbolic links.
    public static func measure(_ url: URL, fileManager: FileManager = .default) -> SizeMeasurement {
        guard let rootValues = try? url.resourceValues(forKeys: rootKeys) else {
            return SizeMeasurement(allocatedBytes: 0, unreadableEntryCount: 1)
        }
        if rootValues.isSymbolicLink == true || rootValues.isDirectory != true {
            let bytes = rootValues.totalFileAllocatedSize ?? rootValues.fileAllocatedSize ?? 0
            return SizeMeasurement(allocatedBytes: Int64(bytes), unreadableEntryCount: 0)
        }

        var unreadable = 0
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: entryKeys,
            options: [],
            errorHandler: { _, _ in
                unreadable += 1
                return true
            }
        ) else {
            return SizeMeasurement(allocatedBytes: 0, unreadableEntryCount: 1)
        }

        var total: Int64 = 0
        var visited = 0
        while let entry = enumerator.nextObject() as? URL {
            visited += 1
            if visited % 2_000 == 0, Task.isCancelled { break }
            guard let values = try? entry.resourceValues(forKeys: Set(entryKeys)), values.isRegularFile == true else {
                continue
            }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return SizeMeasurement(allocatedBytes: total, unreadableEntryCount: unreadable)
    }
}
