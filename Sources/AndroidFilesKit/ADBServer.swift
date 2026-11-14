import Foundation
import Network

/// The adb server on this Mac (the program `adb` starts and talks to), spoken to directly over
/// its socket. A shell command costs one local connection instead of a new `adb` process, and
/// files go through adb's own file channel ("sync"), about four times faster than a shell pipe
/// and with a real answer on failure.
public struct ADBServer: Sendable, Equatable {
    public var host: String
    public var port: UInt16

    public init(host: String = "127.0.0.1", port: UInt16 = 5037) {
        self.host = host
        self.port = port
    }

    /// Where adb's own tools look: ANDROID_ADB_SERVER_PORT, else 5037.
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> ADBServer {
        ADBServer(port: environment["ANDROID_ADB_SERVER_PORT"].flatMap { UInt16($0) } ?? 5037)
    }

    /// The most bytes one piece of a file may hold on the file channel.
    static let dataLimit = 64 * 1024
    /// The tablet's file channel refuses a path longer than 1024 bytes. Longer ones go through the shell.
    static let pathLimit = 1000

    static func fits(_ path: String) -> Bool { path.utf8.count <= pathLimit }

    /// Opens a service on the device: "sync:", "shell,v2,raw:<command>", "exec:<command>".
    func open(_ serial: String, _ service: String) async throws -> ADBSocket {
        let socket = try await ADBSocket(host: host, port: port)
        do {
            // Cancellable: a server that accepts and then says nothing must not hold the caller for ever.
            try await socket.cancellable {
                try await socket.request("host:transport:" + serial)
                try await socket.request(service)
            }
        } catch {
            socket.close()
            throw error
        }
        return socket
    }

    /// Runs a command in the tablet's shell: its output, its errors and its exit status, each on its own.
    public func shell(_ serial: String, _ command: String) async throws -> CommandResult {
        let socket = try await open(serial, "shell,v2,raw:" + command)
        defer { socket.close() }
        return try await socket.cancellable {
            var out = Data(), err = Data()
            // Packets: a kind (1 output, 2 errors, 3 exit status), a length, the bytes.
            while let head = try await socket.read(5, orEnd: true) {
                let count = Int(head.dropFirst().littleEndian32)
                let body = try await socket.read(count)
                switch head[head.startIndex] {
                case 1: out.append(body)
                case 2: err.append(body)
                case 3: return CommandResult(status: Int32(body.first ?? 0), stdout: out, stderr: String(decoding: err, as: UTF8.self))
                default: break
                }
            }
            throw FileError("The tablet closed the connection")
        }
    }

    /// A command's raw output, piece by piece (like `adb exec-out`). No exit status comes back.
    func output(_ serial: String, _ command: String, to sink: @Sendable (Data) async throws -> Bool) async throws {
        let socket = try await open(serial, "exec:" + command)
        defer { socket.close() }
        try await socket.cancellable {
            while let data = try await socket.readSome() {
                guard try await sink(data) else { return }
            }
        }
    }

    /// Reads a whole file through the file channel. `sink` returns false to stop early.
    /// Throws the tablet's own reason when it can't ("open failed: No such file or directory").
    public func pull(_ serial: String, _ path: String, to sink: @Sendable (Data) async throws -> Bool) async throws {
        let socket = try await open(serial, "sync:")
        defer { socket.close() }
        try await socket.cancellable {
            try await socket.write(Self.packet("RECV", Data(path.utf8)))
            while true {
                let head = try await socket.read(8)
                let count = Int(head.dropFirst(4).littleEndian32)
                switch String(decoding: head.prefix(4), as: UTF8.self) {
                case "DATA":
                    guard count <= Self.dataLimit else { throw FileError("The tablet sent a piece that is too large") }
                    guard try await sink(try await socket.read(count)) else { return }
                case "DONE": return
                case "FAIL": throw FileError(String(decoding: try await socket.read(count), as: UTF8.self))
                default: throw FileError("The tablet's answer makes no sense")
                }
            }
        }
    }

    /// Writes a file through the file channel, from the pieces `next` returns until nil.
    /// Returns the number of bytes sent. The tablet answers only when the file is written.
    @discardableResult
    public func push(_ serial: String, _ path: String, modified: Date = .now,
                     from next: @Sendable () async throws -> Data?) async throws -> Int64 {
        let socket = try await open(serial, "sync:")
        defer { socket.close() }
        return try await socket.cancellable {
            // 33188 is a plain file, rw-r--r--. Shared storage sets its own permissions anyway.
            try await socket.write(Self.packet("SEND", Data("\(path),33188".utf8)))
            var sent: Int64 = 0
            do {
                while let data = try await next() {
                    // One write for what came in, cut into pieces of the size the channel takes.
                    var framed = Data(capacity: data.count + 8 * (data.count / Self.dataLimit + 1))
                    var rest = data[...]
                    while !rest.isEmpty {
                        let piece = rest.prefix(Self.dataLimit)
                        rest = rest.dropFirst(piece.count)
                        framed.append(Self.packet("DATA", Data(piece)))
                    }
                    try await socket.write(framed)
                    sent += Int64(data.count)
                }
            } catch let broken as ADBSocketError {
                // The tablet stopped reading: its reason is waiting to be read.
                if let reason = try? await Self.answer(socket) { throw reason }
                throw broken
            }
            var done = Data("DONE".utf8)
            done.appendLittleEndian32(UInt32(max(0, min(modified.timeIntervalSince1970, Double(UInt32.max)))))
            try await socket.write(done)
            if let failure = try await Self.answer(socket) { throw failure }
            return sent
        }
    }

    /// "OKAY", or "FAIL" and the tablet's reason.
    private static func answer(_ socket: ADBSocket) async throws -> FileError? {
        let head = try await socket.read(8)
        if head.prefix(4).elementsEqual("OKAY".utf8) { return nil }
        guard head.prefix(4).elementsEqual("FAIL".utf8) else { return FileError("The tablet's answer makes no sense") }
        return FileError(String(decoding: try await socket.read(Int(head.dropFirst(4).littleEndian32)), as: UTF8.self))
    }

    static func packet(_ kind: String, _ body: Data) -> Data {
        var data = Data(kind.utf8)
        data.appendLittleEndian32(UInt32(body.count))
        data.append(body)
        return data
    }
}

extension Data {
    /// The first four bytes as a number, lowest byte first.
    var littleEndian32: UInt32 {
        prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
    }

    mutating func appendLittleEndian32(_ value: UInt32) {
        append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * UInt32($0))) })
    }
}

/// The connection broke, as opposed to the tablet saying no.
struct ADBSocketError: Error {}

/// One connection to the adb server.
final class ADBSocket: @unchecked Sendable {
    private let connection: NWConnection
    private let lock = NSLock()
    private var buffer = Data()

    init(host: String, port: UInt16) async throws {
        guard let port = NWEndpoint.Port(rawValue: port) else { throw FileError("Can't reach adb") }
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
        connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        let connection = connection
        let once = OnceFlag()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.first() { continuation.resume() }
                case .failed, .cancelled, .waiting:
                    // .waiting: nobody listens there. Don't wait for it to appear.
                    if once.first() {
                        connection.cancel()
                        continuation.resume(throwing: FileError("Can't reach adb on this Mac"))
                    }
                default: break
                }
            }
            connection.start(queue: DispatchQueue(label: "ADBSocket"))
        }
    }

    /// A connection someone made to us (the pretend server in tests).
    init(accepted connection: NWConnection) {
        self.connection = connection
    }

    func close() { connection.cancel() }

    /// Runs `work`; cancelling the task closes the connection, which ends any read or write in it.
    func cancellable<T: Sendable>(_ work: () async throws -> T) async throws -> T {
        try await withTaskCancellationHandler {
            do {
                return try await work()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: {
            close()
        }
    }

    /// The server's own framing: four hex digits of length, then the text. It answers OKAY or FAIL + reason.
    func request(_ text: String) async throws {
        let body = Data(text.utf8)
        guard body.count <= 0xFFFF else { throw FileError("The command is too long for adb") }
        try await write(Data(String(format: "%04x", body.count).utf8) + body)
        let status = try await read(4)
        if status.elementsEqual("OKAY".utf8) { return }
        guard status.elementsEqual("FAIL".utf8), let count = Int(String(decoding: try await read(4), as: UTF8.self), radix: 16) else {
            throw FileError("adb's answer makes no sense")
        }
        throw FileError(String(decoding: try await read(count), as: UTF8.self))
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if error == nil { continuation.resume() } else { continuation.resume(throwing: ADBSocketError()) }
            })
        }
    }

    /// Exactly `count` bytes. With `orEnd`, nil when the connection ended cleanly before the first one.
    func read(_ count: Int, orEnd: Bool) async throws -> Data? {
        while lock.withLock({ buffer.count }) < count {
            guard let more = try await receive() else {
                if orEnd && lock.withLock({ buffer.isEmpty }) { return nil }
                throw ADBSocketError()
            }
            lock.withLock { buffer.append(more) }
        }
        return lock.withLock {
            let data = Data(buffer.prefix(count))
            buffer = Data(buffer.dropFirst(count))
            return data
        }
    }

    func read(_ count: Int) async throws -> Data {
        guard let data = try await read(count, orEnd: false) else { throw ADBSocketError() }
        return data
    }

    /// Whatever arrives next, or nil at the end.
    func readSome() async throws -> Data? {
        let waiting: Data = lock.withLock { defer { buffer = Data() }; return buffer }
        if !waiting.isEmpty { return waiting }
        return try await receive()
    }

    private func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if error != nil {
                    continuation.resume(throwing: ADBSocketError())
                } else if complete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(throwing: ADBSocketError())
                }
            }
        }
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func first() -> Bool { lock.withLock { defer { done = true }; return !done } }
}
