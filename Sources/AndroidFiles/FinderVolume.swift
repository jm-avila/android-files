import AppKit
import Foundation
import AndroidFilesKit

/// The tablet as a volume in Finder: a WebDAV share on 127.0.0.1 (AndroidFilesKit/WebDAV.swift)
/// that macOS mounts with its own mount_webdav. No driver and nothing to install.
/// The volume's name in Finder is the mount folder's name.
///
/// Nothing here may read a mounted volume's own files or attributes: its server is this
/// app, and after a crash nobody answers. Mounts are found in the system's mount table.
final class FinderVolume {
    private var server: HTTPServer?
    private var share: WebDAVShare?
    private(set) var path: String?

    /// Where volumes are mounted. Test runs keep theirs in the APP_STORE folder.
    static var folder: String {
        TestMode.store.map { $0 + "/volumes" } ?? NSHomeDirectory() + "/Library/Application Support/AndroidFiles/Volumes"
    }

    /// "OnePlus Pad Go 2" → "OnePlus-Pad-Go-2.localhost" (Finder shows it in lower case). A name with no
    /// dot is not safe: the network's search domains may resolve it to another machine.
    nonisolated static func hostName(_ name: String) -> String {
        let words = name.split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        return (words.isEmpty ? "android" : words.joined(separator: "-").prefix(50)) + ".localhost"
    }

    /// Serves `root` of the tablet and mounts it. Returns the volume's path.
    func mount(files: FileSystem, content: FileContent, root: String, name: String) async throws -> String {
        await unmount()
        let token = UUID().uuidString.lowercased()
        let share = WebDAVShare(files: files, content: content, root: root, prefix: "/" + token)
        // Finder's sidebar shows the server's host, not the volume's name: "127.0.0.1" says nothing.
        // Every Mac resolves a name ending in .localhost to itself.
        let host = Self.hostName(name)
        let server = try await HTTPServer(name: host, handler: share.handler)
        let safeName = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let path = Self.folder + "/" + safeName
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            // -S: no dialogs. A failure comes back as the exit status.
            let result = try await ProcessRunner().run("/sbin/mount_webdav",
                ["-S", "-v", safeName, "http://\(host):\(server.port)/\(token)/", path])
            guard result.status == 0, Self.isMounted(path) else {
                throw FileError("Finder can't show the tablet: " + (result.stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "the volume did not mount"))
            }
        } catch {
            await Self.detached { Self.forceUnmount(path) }
            server.stop()
            throw error
        }
        self.server = server
        self.share = share
        self.path = path
        return path
    }

    func unmount() async {
        guard let path else { return }
        // Empty files Finder made a moment ago are still waiting to be written (WebDAVShare.pending).
        if let share { await Self.settle(share) }
        share = nil
        // The server goes first: a volume that still gets answers can hold up its own unmount.
        server?.stop()
        server = nil
        self.path = nil
        await Self.detached { Self.forceUnmount(path) }
    }

    /// The volume is gone already (ejected in Finder): stop serving it.
    func closed() {
        if let share { Task { await share.settle() } }
        share = nil
        server?.stop()
        server = nil
        if let path { Self.removeMountFolder(path) }
        path = nil
    }

    /// Waits for the share's last empty files, but not for long: the tablet may be gone.
    private static func settle(_ share: WebDAVShare) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = Once()
            Task { await share.settle(); if once.first() { continuation.resume() } }
            Task { try? await Task.sleep(for: .seconds(3)); if once.first() { continuation.resume() } }
        }
    }

    private static func detached(_ work: @escaping @Sendable () -> Void) async {
        await Task.detached(operation: work).value
    }

    /// Mount points now in the system's mount table, as it writes them (/private/tmp, not /tmp).
    nonisolated static func mountPoints() -> [String] {
        var list: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&list, MNT_NOWAIT)
        defer { free(list) }
        guard let list, count > 0 else { return [] }
        return (0..<Int(count)).map { index in
            withUnsafeBytes(of: &list[index].f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
    }

    /// The path as the mount table writes it: the parent resolved, the last part as is.
    /// (realpath on the whole path would ask the volume itself. URL.resolvingSymlinksInPath
    /// turns /private/tmp back into /tmp.)
    nonisolated static func tablePath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        guard let parent = realpath(url.deletingLastPathComponent().path, nil) else { return path }
        defer { free(parent) }
        return String(cString: parent) + "/" + url.lastPathComponent
    }

    nonisolated static func isMounted(_ path: String) -> Bool {
        mountPoints().contains(tablePath(path))
    }

    /// Unmounts without asking the volume (it may have nobody to answer), then removes its folder.
    nonisolated static func forceUnmount(_ path: String) {
        if isMounted(path) { _ = Darwin.unmount(tablePath(path), MNT_FORCE) }
        removeMountFolder(path)
    }

    /// Removes the empty folder a volume was mounted on. rmdir only, and never while mounted:
    /// a recursive delete here would run through the volume and erase the tablet's files.
    nonisolated static func removeMountFolder(_ path: String) {
        if !isMounted(path) { rmdir(path) }
    }

    /// Unmounts whatever is left in the volumes folder: at quit, and at launch after a crash
    /// (a volume whose app is gone would make Finder wait).
    nonisolated static func unmountAll(in folder: String) {
        let base = tablePath(folder + "/x").dropLast(1)
        for point in mountPoints() where point.hasPrefix(base) { _ = Darwin.unmount(point, MNT_FORCE) }
        // The folders left behind are empty. Names only: no attributes are read.
        guard let dir = opendir(folder) else { return }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: &entry.pointee.d_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if name != "." && name != ".." { names.append(name) }
        }
        closedir(dir)
        for name in names { removeMountFolder(folder + "/" + name) }
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func first() -> Bool { lock.withLock { defer { done = true }; return !done } }
}
