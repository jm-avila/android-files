import Foundation

/// A file's bytes as a stream, for the Finder volume: Finder reads and writes
/// through the app, piece by piece, so a big video never sits in memory.
public protocol FileContent: Sendable {
    /// Hands the bytes from `offset` on to `sink`, in order, up to `length` of them (nil: to the end).
    /// `sink` is awaited before the next piece is read.
    func read(_ path: String, from offset: Int64, length: Int64?,
              to sink: @Sendable (Data) async throws -> Void) async throws
    /// Creates or replaces the file with the pieces `next` returns, until it returns nil.
    /// A failure leaves no half-written file under `path`.
    func write(_ path: String, from next: @Sendable () async throws -> Data?) async throws
    /// Creates a small file that is not there yet, in as few steps as the storage allows.
    /// A failure leaves nothing under `path`.
    func create(_ path: String, holding data: Data) async throws
    /// Bytes used and free on the storage that holds `path`, when it can tell.
    func space(_ path: String) async -> StorageSpace?
}

extension FileContent {
    public func create(_ path: String, holding data: Data) async throws {
        let once = OnePiece(data)
        try await write(path) { once.next() }
    }
}

/// Hands out its data once, then nil.
final class OnePiece: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    init(_ data: Data) { self.data = data.isEmpty ? nil : data }
    func next() -> Data? { lock.withLock { defer { data = nil }; return data } }
}

public struct StorageSpace: Sendable, Equatable {
    public var used: Int64
    public var free: Int64

    public init(used: Int64, free: Int64) {
        self.used = used
        self.free = free
    }
}

/// How much one read or write moves at a time.
let contentChunk = 256 * 1024

extension LocalFileSystem: FileContent {
    public func read(_ path: String, from offset: Int64, length: Int64?,
                     to sink: @Sendable (Data) async throws -> Void) async throws {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url(path)) } catch { throw FileError(Self.reason(error)) }
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        var left = length ?? .max
        while left > 0 {
            guard let data = try handle.read(upToCount: Int(min(Int64(contentChunk), left))), !data.isEmpty else { return }
            left -= Int64(data.count)
            try await sink(data)
        }
    }

    public func write(_ path: String, from next: @Sendable () async throws -> Data?) async throws {
        let target = url(path)
        let part = target.deletingLastPathComponent().appending(path: ".\(target.lastPathComponent)\(partMark)\(UUID().uuidString.prefix(8))")
        guard FileManager.default.createFile(atPath: part.path, contents: nil) else {
            throw FileError("Can't create “\(FilePath.name(path))”")
        }
        do {
            let handle = try FileHandle(forWritingTo: part)
            defer { try? handle.close() }
            while let data = try await next() { try handle.write(contentsOf: data) }
            _ = try FileManager.default.replaceItemAt(target, withItemAt: part)
        } catch {
            try? FileManager.default.removeItem(at: part)
            throw error is CancellationError ? error : FileError(Self.reason(error))
        }
    }

    public func space(_ path: String) async -> StorageSpace? {
        guard let values = try? FileManager.default.attributesOfFileSystem(forPath: url(path).path),
              let total = values[.systemSize] as? Int64, let free = values[.systemFreeSize] as? Int64 else { return nil }
        return StorageSpace(used: total - free, free: free)
    }
}

extension ADBOutput {
    /// The last line of `df -k <path>`: "/dev/fuse 111381484 52011304 59239108 47% /storage/emulated".
    public static func space(_ text: String) -> StorageSpace? {
        guard let line = text.split(whereSeparator: \.isNewline).last else { return nil }
        let fields = line.split(separator: " ")
        guard fields.count >= 4, let used = Int64(fields[2]), let free = Int64(fields[3]) else { return nil }
        return StorageSpace(used: used * 1024, free: free * 1024)
    }
}

extension ADBFileSystem: FileContent {
    /// `dd` seeks to a whole block; the bytes before `offset` inside it are dropped here.
    /// exec-out sends stderr down the same pipe, so errors and dd's summary go to /dev/null:
    /// a short answer is the sign of a failure, never an error's text served as the file.
    static let readBlock: Int64 = 65_536

    public static func readCommand(_ path: String, from offset: Int64) -> String {
        offset == 0 ? "cat -- \(shellQuote(path)) 2>/dev/null"
            : "dd if=\(shellQuote(path)) bs=\(readBlock) skip=\(offset / readBlock) 2>/dev/null"
    }

    /// exec-in returns before the tablet has written the last bytes, or even made the file (a real
    /// one was 12 MB behind for two seconds, and under load 1 upload in 75 had no file yet). So the
    /// upload counts as broken only once the part has stopped growing for 10 s short of its size,
    /// or has not appeared for 2 s (a refused name).
    public static func commitCommand(part: String, path: String, bytes: Int64) -> String {
        let part = shellQuote(part)
        return "i=0; last=; while :; do s=$(stat -c %s -- \(part) 2>/dev/null); [ \"$s\" = \(bytes) ] && break; "
            + "if [ \"$s\" = \"$last\" ]; then i=$((i+1)); else i=0; last=$s; fi; "
            + "if [ -z \"$s\" ]; then m=20; else m=100; fi; [ $i -ge $m ] && break; sleep 0.1; done; "
            + "[ \"$s\" = \(bytes) ] && mv -- \(part) \(shellQuote(path))"
    }

    public func read(_ path: String, from offset: Int64, length: Int64?,
                     to sink: @Sendable (Data) async throws -> Void) async throws {
        if let server = adb.server, ADBServer.fits(path) {
            try await read(path, from: offset, length: length, through: server, to: sink)
            return
        }
        let stream = try ProcessStream(adb.path, ["-s", serial, "exec-out", Self.readCommand(path, from: offset)], input: false)
        var skip = offset == 0 ? 0 : Int(offset % Self.readBlock)
        var left = length ?? .max
        do {
            while left > 0, var data = await stream.read() {
                if skip > 0 {
                    let dropped = min(skip, data.count)
                    data.removeFirst(dropped)
                    skip -= dropped
                    if data.isEmpty { continue }
                }
                if Int64(data.count) > left { data = data.prefix(Int(left)) }
                left -= Int64(data.count)
                try await sink(data)
            }
        } catch {
            stream.stop()
            throw error
        }
        // Enough bytes read: the rest of the file is not wanted.
        if left == 0 { stream.stop(); return }
        _ = await stream.finish()
        // exec-out reports no failure of its own: a short answer is the sign.
        if length != nil && left > 0 {
            throw FileError("Can't read “\(FilePath.name(path))” from the tablet")
        }
    }

    /// The direct way: the file channel from the start of a file, `dd` from inside one.
    private func read(_ path: String, from offset: Int64, length: Int64?, through server: ADBServer,
                      to sink: @Sendable (Data) async throws -> Void) async throws {
        let left = Remaining(length ?? .max, skip: offset == 0 ? 0 : Int(offset % Self.readBlock))
        let take: @Sendable (Data) async throws -> Bool = { data in
            guard let piece = left.take(data) else { return !left.isDone }
            try await sink(piece)
            return !left.isDone
        }
        if offset == 0 {
            try await server.pull(serial, path, to: take)
        } else {
            try await server.output(serial, Self.readCommand(path, from: offset), to: take)
        }
        if length != nil && !left.isDone {
            throw FileError("Can't read “\(FilePath.name(path))” from the tablet")
        }
    }

    /// A new small file goes straight to its name over the file channel: one step instead of
    /// three. Nothing is there to protect, and the tablet itself removes a file it could not
    /// finish: nothing is deleted from here, where a failure may mean the tablet never heard of it.
    public func create(_ path: String, holding data: Data) async throws {
        let once = OnePiece(data)
        guard let server = adb.server, ADBServer.fits(path) else {
            return try await write(path) { once.next() }
        }
        try await server.push(serial, path) { once.next() }
    }

    /// Written under another name first, so a broken upload never replaces the file.
    public func write(_ path: String, from next: @Sendable () async throws -> Data?) async throws {
        let part = FilePath.join(FilePath.parent(path), ".\(FilePath.name(path))\(partMark)\(UUID().uuidString.prefix(8))")
        if let server = adb.server, ADBServer.fits(part) {
            do {
                // The file channel makes missing folders on its way: the folder must be there first.
                // It answers when the file is written; the size is checked all the same.
                let sent = try await server.push(serial, part, from: next)
                let result = try await adb.shell(serial, Self.commitCommand(part: part, path: path, bytes: sent))
                guard result.status == 0 else { throw FileError("Can't write “\(FilePath.name(path))” on the tablet") }
            } catch {
                // Not through this task: when it was cancelled, the clean-up must still run.
                _ = await Task.detached { [adb, serial] in try? await adb.shell(serial, "rm -f -- \(shellQuote(part))") }.value
                throw error
            }
            return
        }
        let stream = try ProcessStream(adb.path, ["-s", serial, "exec-in", "cat > \(shellQuote(part))"], input: true)
        do {
            var sent: Int64 = 0
            while let data = try await next() {
                try await stream.write(data)
                sent += Int64(data.count)
            }
            _ = await stream.finish()
            // exec-in reports no failure of its own (a full tablet, a refused name): the file
            // replaces the old one only when every byte arrived.
            let result = try await adb.shell(serial, Self.commitCommand(part: part, path: path, bytes: sent))
            guard result.status == 0 else { throw FileError("Can't write “\(FilePath.name(path))” on the tablet") }
        } catch {
            stream.stop()
            _ = try? await adb.shell(serial, "rm -f -- \(shellQuote(part))")
            throw error
        }
    }

    public func space(_ path: String) async -> StorageSpace? {
        guard let result = try? await adb.shell(serial, "df -k \(shellQuote(path))"), result.status == 0 else { return nil }
        return ADBOutput.space(result.text)
    }
}

/// Counts down what a read still owes: bytes to drop first, then bytes to hand on.
private final class Remaining: @unchecked Sendable {
    private let lock = NSLock()
    private var left: Int64
    private var skip: Int

    init(_ length: Int64, skip: Int) {
        left = length
        self.skip = skip
    }

    var isDone: Bool { lock.withLock { left == 0 } }

    /// The part of `data` that is wanted, or nil when none of it is.
    func take(_ data: Data) -> Data? {
        lock.withLock {
            var data = data
            if skip > 0 {
                let dropped = min(skip, data.count)
                data = Data(data.dropFirst(dropped))
                skip -= dropped
            }
            if Int64(data.count) > left { data = Data(data.prefix(Int(left))) }
            left -= Int64(data.count)
            return data.isEmpty ? nil : data
        }
    }
}

/// A running program whose output is read, or whose input is written, piece by piece.
final class ProcessStream: @unchecked Sendable {
    private let process = Process()
    private let output = Pipe()
    private let input: Pipe?
    private let queue = DispatchQueue(label: "ProcessStream")
    private let exited = DispatchSemaphore(value: 0)

    init(_ executable: String, _ arguments: [String], input wantsInput: Bool) throws {
        // A program that stops reading must fail the write, not end this app.
        signal(SIGPIPE, SIG_IGN)
        (process.executableURL, process.arguments) = ExactArguments.launch(executable, arguments)
        input = wantsInput ? Pipe() : nil
        process.standardInput = input ?? FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // Not waitUntilExit: off the main thread it can wait for ever on a program that has ended.
        process.terminationHandler = { [exited] _ in exited.signal() }
        do { try process.run() } catch { throw FileError("Can't run \(executable): \(error.localizedDescription)") }
    }

    /// The next piece of output, or nil at the end.
    func read() async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async {
                let data = self.output.fileHandleForReading.availableData
                continuation.resume(returning: data.isEmpty ? nil : data)
            }
        }
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.input?.fileHandleForWriting.write(contentsOf: data)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: FileError("The tablet stopped taking the file"))
                }
            }
        }
    }

    /// Closes the input, waits for the end, and returns the exit status.
    func finish() async -> Int32 {
        await withCheckedContinuation { continuation in
            queue.async {
                try? self.input?.fileHandleForWriting.close()
                self.exited.wait()
                continuation.resume(returning: self.process.terminationStatus)
            }
        }
    }

    func stop() {
        if process.isRunning { process.terminate() }
        try? input?.fileHandleForWriting.close()
    }
}
