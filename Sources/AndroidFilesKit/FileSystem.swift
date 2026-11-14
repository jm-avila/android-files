import Foundation

/// What the Finder volume needs from the tablet's storage. Tests use a folder in /tmp in its place.
public protocol FileSystem: Sendable {
    func list(_ folder: String) async throws -> [FileEntry]
    func exists(_ path: String) async throws -> Bool
    func makeFolder(_ path: String) async throws
    /// Renames or moves within this side. `to` is the full new path.
    func move(_ path: String, to: String) async throws
    /// Copies a file or folder within this side. `to` is the full new path.
    func copy(_ path: String, to: String) async throws
    /// The Mac moves items to the Trash; the tablet deletes them for good.
    func delete(_ path: String) async throws
    /// Bytes in a file, or in everything inside a folder.
    func size(_ path: String) async throws -> Int64
    /// True when `delete` cannot be undone.
    var deletesPermanently: Bool { get }
}

public struct FileError: LocalizedError, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
