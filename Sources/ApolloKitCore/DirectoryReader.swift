import Darwin
import Foundation

/// Reads a directory's entries with `getattrlistbulk(2)`, which returns name, type, device and
/// allocated size for many entries per system call. Several times faster than `FileManager` with
/// resource keys, which matters when mapping millions of files.
enum DirectoryReader {
    struct Entry: Sendable {
        enum Kind: Sendable { case file, directory, symbolicLink, other }

        let name: String
        let kind: Kind
        let device: dev_t
        /// Space allocated for all forks; 0 for directories.
        let allocatedBytes: Int64
    }

    /// `nil` when the directory can't be opened, e.g. because of privacy protection.
    static func entries(atPath path: String) -> [Entry]? {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var attributes = attrlist()
        attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_DEVID)
            | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_ERROR)
        attributes.fileattr = attrgroup_t(ATTR_FILE_ALLOCSIZE)

        let bufferSize = 128 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buffer.deallocate() }

        var result: [Entry] = []
        while true {
            let count = getattrlistbulk(descriptor, &attributes, buffer, bufferSize, 0)
            if count < 0 { return result.isEmpty ? nil : result }
            if count == 0 { return result }

            var entryStart = buffer
            for _ in 0..<count {
                let length = Int(entryStart.loadUnaligned(as: UInt32.self))
                if let entry = parse(entryStart) { result.append(entry) }
                entryStart += length
            }
        }
    }

    /// Fields follow the length and the returned-attributes set, in attribute bit order, each 4-byte aligned.
    private static func parse(_ start: UnsafeMutableRawPointer) -> Entry? {
        var cursor = start + MemoryLayout<UInt32>.size
        let returned = cursor.loadUnaligned(as: attribute_set_t.self)
        cursor += MemoryLayout<attribute_set_t>.size

        var name = ""
        if returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 {
            let reference = cursor.loadUnaligned(as: attrreference_t.self)
            name = String(cString: (cursor + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
            cursor += MemoryLayout<attrreference_t>.size
        }
        var device: dev_t = 0
        if returned.commonattr & attrgroup_t(ATTR_CMN_DEVID) != 0 {
            device = cursor.loadUnaligned(as: dev_t.self)
            cursor += MemoryLayout<dev_t>.size
        }
        var type = fsobj_type_t(VNON.rawValue)
        if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
            type = cursor.loadUnaligned(as: fsobj_type_t.self)
            cursor += MemoryLayout<fsobj_type_t>.size
        }
        if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 {
            let error = cursor.loadUnaligned(as: UInt32.self)
            cursor += MemoryLayout<UInt32>.size
            if error != 0 { return nil }
        }
        var allocated: Int64 = 0
        if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
            allocated = cursor.loadUnaligned(as: off_t.self)
        }

        guard !name.isEmpty else { return nil }
        let kind: Entry.Kind = switch type {
        case fsobj_type_t(VREG.rawValue): .file
        case fsobj_type_t(VDIR.rawValue): .directory
        case fsobj_type_t(VLNK.rawValue): .symbolicLink
        default: .other
        }
        return Entry(name: name, kind: kind, device: device, allocatedBytes: allocated)
    }
}
