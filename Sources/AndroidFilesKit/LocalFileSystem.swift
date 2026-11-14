import Foundation

/// The Mac's files through FileManager. `root` maps the side's paths onto a
/// real folder: "/" for the Mac itself, a /tmp folder for a pretend tablet.
public struct LocalFileSystem: FileSystem {
    public let root: String
    public let deletesPermanently: Bool

    /// `useTrash`: delete moves to the Trash (the real Mac). Otherwise it removes.
    public init(root: String = "/", useTrash: Bool = true) {
        self.root = root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
        self.deletesPermanently = !useTrash
    }

    /// The real location of a side path.
    public func url(_ path: String) -> URL {
        URL(fileURLWithPath: root == "/" ? path : root + path)
    }

    public func list(_ folder: String) async throws -> [FileEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(at: url(folder), includingPropertiesForKeys: keys)
        } catch {
            throw FileError("Can't open “\(FilePath.name(folder))”: \(Self.reason(error))")
        }
        return urls.map { item in
            let values = try? item.resourceValues(forKeys: Set(keys))
            let name = item.lastPathComponent
            // Follow symlinks for the kind, like Finder does for aliases to folders.
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir)
            let kind: FileEntry.Kind = isDir.boolValue ? .folder : (values?.isRegularFile == true ? .file : .other)
            return FileEntry(name: name, path: FilePath.join(folder, name), kind: kind,
                             size: Int64(values?.fileSize ?? 0),
                             modified: values?.contentModificationDate ?? .distantPast)
        }
    }

    public func exists(_ path: String) async throws -> Bool {
        FileManager.default.fileExists(atPath: url(path).path)
    }

    public func size(_ path: String) async throws -> Int64 {
        let url = url(path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw FileError("“\(FilePath.name(path))” is gone")
        }
        guard isDir.boolValue else {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        var total: Int64 = 0
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        while let item = files?.nextObject() as? URL {
            let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    public func makeFolder(_ path: String) async throws {
        try wrap { try FileManager.default.createDirectory(at: url(path), withIntermediateDirectories: false) }
    }

    public func move(_ path: String, to: String) async throws {
        try wrap { try FileManager.default.moveItem(at: url(path), to: url(to)) }
    }

    public func copy(_ path: String, to: String) async throws {
        try wrap { try FileManager.default.copyItem(at: url(path), to: url(to)) }
    }

    public func delete(_ path: String) async throws {
        try wrap {
            if deletesPermanently {
                try FileManager.default.removeItem(at: url(path))
            } else {
                try FileManager.default.trashItem(at: url(path), resultingItemURL: nil)
            }
        }
    }

    private func wrap(_ body: () throws -> Void) throws {
        do { try body() } catch { throw FileError(Self.reason(error)) }
    }

    /// The short reason from a Cocoa error, without the file URL noise.
    static func reason(_ error: Error) -> String {
        let ns = error as NSError
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           let posix = POSIXErrorCode(rawValue: Int32(underlying.code)), underlying.domain == NSPOSIXErrorDomain {
            return String(cString: strerror(posix.rawValue))
        }
        return ns.localizedDescription
    }
}
