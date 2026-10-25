import Foundation

public struct SizeMeasurement: Sendable, Equatable {
    public let allocatedBytes: Int64
    public let unreadableEntryCount: Int
    /// Only looked for when requested: at least one Mach-O binary or script with its executable bit set.
    public var containsPrograms = false
}

public enum DirectorySizer {
    private static let entryKeys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
    private static let rootKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
    ]

    /// Sums allocated sizes without following symbolic links.
    /// - Parameter detectsPrograms: also reports whether the tree holds programs, at the cost of one extra
    ///   check per file until the first one is found.
    public static func measure(_ url: URL, detectsPrograms: Bool = false, fileManager: FileManager = .default) -> SizeMeasurement {
        guard let rootValues = try? url.resourceValues(forKeys: rootKeys) else {
            return SizeMeasurement(allocatedBytes: 0, unreadableEntryCount: 1)
        }
        if rootValues.isSymbolicLink == true || rootValues.isDirectory != true {
            let bytes = rootValues.totalFileAllocatedSize ?? rootValues.fileAllocatedSize ?? 0
            let isProgram = detectsPrograms && rootValues.isSymbolicLink != true && isProgram(url)
            return SizeMeasurement(allocatedBytes: Int64(bytes), unreadableEntryCount: 0, containsPrograms: isProgram)
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
        var containsPrograms = false
        while let entry = enumerator.nextObject() as? URL {
            visited += 1
            if visited % 2_000 == 0, Task.isCancelled { break }
            guard let values = try? entry.resourceValues(forKeys: Set(entryKeys)), values.isRegularFile == true else {
                continue
            }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            if detectsPrograms, !containsPrograms, isProgram(entry) {
                containsPrograms = true
            }
        }
        return SizeMeasurement(allocatedBytes: total, unreadableEntryCount: unreadable, containsPrograms: containsPrograms)
    }

    /// Executable bit plus a Mach-O or `#!` header, so data files that merely have the bit set do not count.
    /// Dynamic libraries are Mach-O too, which is intended: tools load their native modules from caches.
    static func isProgram(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IXUSR != 0,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 4), header.count >= 2 else { return false }
        if header.starts(with: [0x23, 0x21]) { return true }
        guard header.count == 4 else { return false }
        let machOMagics: Set<[UInt8]> = [
            [0xFE, 0xED, 0xFA, 0xCE], [0xFE, 0xED, 0xFA, 0xCF], [0xCE, 0xFA, 0xED, 0xFE], [0xCF, 0xFA, 0xED, 0xFE],
            [0xCA, 0xFE, 0xBA, 0xBE], [0xBE, 0xBA, 0xFE, 0xCA],
        ]
        return machOMagics.contains(Array(header))
    }
}
