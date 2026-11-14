import Foundation

/// The two sides the app shows: this Mac and the connected tablet.
public enum Side: String, Sendable, CaseIterable, Hashable, Codable {
    case mac, device

    public var other: Side { self == .mac ? .device : .mac }
}

/// One file or folder in a listing.
public struct FileEntry: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable { case folder, file, other }

    public var name: String
    /// The full path in its side's namespace ("/sdcard/DCIM" on the tablet).
    public var path: String
    public var kind: Kind
    public var size: Int64
    public var modified: Date

    public var id: String { path }
    public var isFolder: Bool { kind == .folder }
    public var isHidden: Bool { name.hasPrefix(".") }

    public init(name: String, path: String, kind: Kind, size: Int64, modified: Date) {
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.modified = modified
    }

    /// Folders first, then by name the way Finder sorts ("file 2" before "file 10").
    public static func finderOrder(_ a: FileEntry, _ b: FileEntry) -> Bool {
        if a.isFolder != b.isFolder { return a.isFolder }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

/// Path helpers for POSIX paths on either side. Paths are absolute and use "/".
public enum FilePath {
    public static func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    public static func parent(_ path: String) -> String {
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let slash = trimmed.lastIndex(of: "/") else { return "/" }
        let parent = String(trimmed[..<slash])
        return parent.isEmpty ? "/" : parent
    }

    public static func name(_ path: String) -> String {
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? "/"
    }

    /// True when `path` is `folder` itself or anything inside it.
    public static func isInside(_ path: String, _ folder: String) -> Bool {
        let base = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        return path == base || path.hasPrefix(base + "/")
    }

    /// A name a person may type for a new file or folder.
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    /// Characters Android's shared storage refuses in a name (as the tablet answers "Operation not permitted").
    public static let androidForbidden = CharacterSet(charactersIn: "\"*:<>?\\|").union(.controlCharacters)

    public static func isAndroidSafe(_ name: String) -> Bool {
        name.unicodeScalars.allSatisfy { !androidForbidden.contains($0) }
    }

    /// "a:b?.txt" → "a_b_.txt": each character Android refuses becomes "_".
    public static func androidSafeName(_ name: String) -> String {
        String(String.UnicodeScalarView(name.unicodeScalars.map { androidForbidden.contains($0) ? "_" : $0 }))
    }

    /// "photo.jpg" → "photo 2.jpg", "photo 3.jpg", ... the first that is not taken.
    /// Folders and names without an extension get the number at the end. Case is
    /// ignored, like on APFS and Android shared storage ("Photo.jpg" takes "photo.jpg").
    public static func uniqueName(_ name: String, isFolder: Bool, taken: Set<String>) -> String {
        let taken = Set(taken.map { $0.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        let ext = isFolder ? "" : (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        var number = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)"
            if !taken.contains(candidate.lowercased()) { return candidate }
            number += 1
        }
    }
}
