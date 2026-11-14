import Foundation
import Testing
@testable import AndroidFilesKit

/// A Mac folder and a pretend tablet folder under /tmp, removed after each test.
final class Sandbox {
    let root: URL
    let mac: LocalFileSystem
    let device: LocalFileSystem

    init() throws {
        root = URL(fileURLWithPath: "/tmp/AndroidFiles-unit-\(UUID().uuidString)")
        for dir in ["mac/Users/me", "device/sdcard/Download"] {
            try FileManager.default.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true)
        }
        // useTrash: false, so tests never fill the real Trash.
        mac = LocalFileSystem(root: root.appending(path: "mac").path, useTrash: false)
        device = LocalFileSystem(root: root.appending(path: "device").path, useTrash: false)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func write(_ side: Side, _ path: String, _ text: String = "data") throws {
        let url = (side == .mac ? mac : device).url(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ side: Side, _ path: String) -> String? {
        (try? Data(contentsOf: (side == .mac ? mac : device).url(path))).map { String(decoding: $0, as: UTF8.self) }
    }

    func names(_ side: Side, _ folder: String) async throws -> [String] {
        try await (side == .mac ? mac : device).list(folder).map(\.name).sorted()
    }

    func entry(_ side: Side, _ path: String) async throws -> FileEntry {
        let fs: FileSystem = side == .mac ? mac : device
        return try #require(try await fs.list(FilePath.parent(path)).first { $0.path == path })
    }
}
