import Foundation
import Network
import Testing
@testable import AndroidFilesKit

/// A pretend adb server on a free local port, speaking what the app uses of adb's protocol:
/// one device ("TAB1"), shell commands answered by `shell`, raw output by `output`, and files
/// kept in a /tmp folder for the file channel.
final class PretendADBServer: @unchecked Sendable {
    let folder = URL(fileURLWithPath: "/tmp/AndroidFiles-adbserver-\(UUID().uuidString)")
    let listener: NWListener
    private(set) var port: UInt16 = 0
    private let lock = NSLock()
    private var _commands: [String] = []
    var commands: [String] { lock.withLock { _commands } }
    /// A shell command's output, errors and exit status. nil: never answer (a tablet that hangs).
    var shell: @Sendable (String) -> (String, String, UInt8)? = { _ in ("", "", 0) }
    var output: @Sendable (String) -> Data = { _ in Data() }
    /// Names the pretend tablet refuses, as Android does.
    var refuses: @Sendable (String) -> Bool = { $0.contains(":") }
    /// Stop taking a file after this many bytes, with a reason (a full tablet).
    var full: Int?
    /// Take connections and say nothing (a server that is stuck).
    var silent = false

    init() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "PretendADBServer")
        listener.newConnectionHandler = { [unowned self] connection in
            connection.start(queue: queue)
            Task { try? await self.serve(ADBSocket(accepted: connection)) }
        }
        let listener = listener
        port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { state in
                if case .ready = state { listener.stateUpdateHandler = nil; continuation.resume(returning: listener.port?.rawValue ?? 0) }
                if case .failed(let error) = state { listener.stateUpdateHandler = nil; continuation.resume(throwing: error) }
            }
            listener.start(queue: queue)
        }
    }

    deinit {
        listener.cancel()
        try? FileManager.default.removeItem(at: folder)
    }

    var server: ADBServer { ADBServer(port: port) }
    func url(_ path: String) -> URL { folder.appending(path: path) }

    private func request(_ socket: ADBSocket) async throws -> String {
        let count = Int(String(decoding: try await socket.read(4), as: UTF8.self), radix: 16) ?? 0
        return String(decoding: try await socket.read(count), as: UTF8.self)
    }

    private func fail(_ socket: ADBSocket, _ reason: String) async throws {
        try await socket.write(Data("FAIL\(String(format: "%04x", reason.utf8.count))\(reason)".utf8))
        socket.close()
    }

    private func serve(_ socket: ADBSocket) async throws {
        defer { socket.close() }
        if silent { return try await Task.sleep(for: .seconds(30)) }
        let transport = try await request(socket)
        guard transport == "host:transport:TAB1" else {
            return try await fail(socket, "device '\(transport.split(separator: ":").last ?? "")' not found")
        }
        try await socket.write(Data("OKAY".utf8))
        let service = try await request(socket)
        try await socket.write(Data("OKAY".utf8))
        if service.hasPrefix("shell,v2,raw:") {
            let command = String(service.dropFirst(13))
            lock.withLock { _commands.append(command) }
            guard let (out, err, status) = shell(command) else {
                try await Task.sleep(for: .seconds(30))
                return
            }
            func packet(_ kind: UInt8, _ body: Data) -> Data {
                var data = Data([kind])
                data.appendLittleEndian32(UInt32(body.count))
                return data + body
            }
            try await socket.write(packet(1, Data(out.utf8)) + packet(2, Data(err.utf8)) + packet(3, Data([status])))
        } else if service.hasPrefix("exec:") {
            try await socket.write(output(String(service.dropFirst(5))))
        } else if service == "sync:" {
            try await sync(socket)
        }
    }

    private func sync(_ socket: ADBSocket) async throws {
        while let head = try await socket.read(8, orEnd: true) {
            let kind = String(decoding: head.prefix(4), as: UTF8.self)
            let name = String(decoding: try await socket.read(Int(head.dropFirst(4).littleEndian32)), as: UTF8.self)
            func answer(_ kind: String, _ text: String = "") async throws {
                try await socket.write(ADBServer.packet(kind, Data(text.utf8)))
            }
            switch kind {
            case "RECV":
                guard let data = try? Data(contentsOf: url(name)) else {
                    return try await answer("FAIL", "open failed: No such file or directory")
                }
                var rest = data[...]
                while !rest.isEmpty {
                    let piece = rest.prefix(ADBServer.dataLimit)
                    rest = rest.dropFirst(piece.count)
                    try await socket.write(ADBServer.packet("DATA", Data(piece)))
                }
                try await answer("DONE")
            case "SEND":
                let path = String(name[..<(name.lastIndex(of: ",") ?? name.endIndex)])
                var data = Data()
                var refused = refuses(path) ? "couldn't create file: Operation not permitted" : nil
                receiving: while true {
                    let head = try await socket.read(8)
                    let count = Int(head.dropFirst(4).littleEndian32)
                    switch String(decoding: head.prefix(4), as: UTF8.self) {
                    case "DATA":
                        data.append(try await socket.read(count))
                        if let full, data.count > full {
                            // Like adbd: say why and stop reading.
                            return try await answer("FAIL", "write failed: No space left on device")
                        }
                    case "DONE": break receiving
                    default: refused = "unknown"; break receiving
                    }
                }
                if let refused { return try await answer("FAIL", refused) }
                // adbd makes the folders on the way.
                try FileManager.default.createDirectory(at: url(path).deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url(path))
                try await answer("OKAY")
            default:
                return
            }
        }
    }
}

@Suite("adb server, directly")
struct ADBServerTests {
    let pretend: PretendADBServer

    init() async throws { pretend = try await PretendADBServer() }

    @Test func shellGivesOutputErrorsAndStatusApart() async throws {
        pretend.shell = { command in command == "ls /nope" ? ("", "ls: /nope: No such file or directory\n", 1) : ("hi ñ\n", "", 0) }
        let ok = try await pretend.server.shell("TAB1", "echo 'hi ñ'")
        #expect(ok == CommandResult(status: 0, stdout: Data("hi ñ\n".utf8), stderr: ""))
        let failed = try await pretend.server.shell("TAB1", "ls /nope")
        #expect(failed.status == 1 && failed.stdout.isEmpty && failed.stderr == "ls: /nope: No such file or directory\n")
        // The command arrives byte for byte: no program in between re-spells accents.
        #expect(pretend.commands.first.map { Array($0.utf8) } == Array("echo 'hi ñ'".utf8))
    }

    @Test func anotherTabletOrNoServerIsAnError() async throws {
        await #expect(throws: FileError("device 'OTHER' not found")) { try await pretend.server.shell("OTHER", "true") }
        pretend.listener.cancel()
        try await Task.sleep(for: .milliseconds(200))
        await #expect(throws: FileError.self) { try await pretend.server.shell("TAB1", "true") }
    }

    @Test func filesGoBothWaysByteForByte() async throws {
        let bytes = Data((0..<700_001).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ $0 / 255) })
        let source = Chunks(bytes, size: 250_000)
        let sent = try await pretend.server.push("TAB1", "/sdcard/it's ñ.bin") { source.next() }
        #expect(sent == 700_001)
        #expect(try Data(contentsOf: pretend.url("/sdcard/it's ñ.bin")) == bytes)
        let got = Chunks(Data(), size: 1)
        try await pretend.server.pull("TAB1", "/sdcard/it's ñ.bin") { got.append($0); return true }
        #expect(got.all == bytes)
        // An empty file is a file.
        try await pretend.server.push("TAB1", "/sdcard/empty") { nil }
        #expect(try Data(contentsOf: pretend.url("/sdcard/empty")).isEmpty)
        let none = Chunks(Data(), size: 1)
        try await pretend.server.pull("TAB1", "/sdcard/empty") { none.append($0); return true }
        #expect(none.all.isEmpty)
    }

    @Test func aReadStopsWhenEnoughArrived() async throws {
        try Data(repeating: 7, count: 1_000_000).write(to: pretend.url("big.bin"))
        let got = Chunks(Data(), size: 1)
        try await pretend.server.pull("TAB1", "big.bin") { got.append($0); return false }
        #expect(got.all.count == ADBServer.dataLimit)
    }

    @Test func theTabletsRefusalsComeBackWithTheirReason() async throws {
        await #expect(throws: FileError("open failed: No such file or directory")) {
            try await pretend.server.pull("TAB1", "/sdcard/missing") { _ in true }
        }
        let text = Chunks(Data("x".utf8), size: 10)
        await #expect(throws: FileError("couldn't create file: Operation not permitted")) {
            try await pretend.server.push("TAB1", "/sdcard/a:b.txt") { text.next() }
        }
        // A tablet that fills up halfway.
        pretend.full = 200_000
        let big = Chunks(Data(repeating: 1, count: 3_000_000), size: 100_000)
        await #expect(throws: FileError.self) { try await pretend.server.push("TAB1", "/sdcard/big.bin") { big.next() } }
        #expect(!FileManager.default.fileExists(atPath: pretend.url("/sdcard/big.bin").path))
        // The reader's own failure passes through as it is.
        struct Broken: Error {}
        await #expect(throws: Broken.self) { try await pretend.server.push("TAB1", "/sdcard/c.txt") { throw Broken() } }
    }

    @Test func cancellingEndsACommandThatHangs() async throws {
        pretend.shell = { _ in nil }
        let server = pretend.server
        let task = Task { try await server.shell("TAB1", "sleep 1000") }
        try await Task.sleep(for: .milliseconds(300))
        let started = Date.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date.now.timeIntervalSince(started) < 2)
    }

    @Test func cancellingEndsAConnectionToAServerThatSaysNothing() async throws {
        let pretend = try await PretendADBServer()
        pretend.silent = true
        let server = pretend.server
        let started = Date.now
        await #expect(throws: (any Error).self) {
            try await withTimeout(.milliseconds(300), "too slow") { try await server.shell("TAB1", "echo hi") }
        }
        #expect(Date.now.timeIntervalSince(started) < 3)
    }

    @Test func pathsTooLongForTheFileChannelAreToldApart() {
        #expect(ADBServer.fits("/sdcard/" + String(repeating: "a", count: 900)))
        #expect(!ADBServer.fits("/sdcard/" + String(repeating: "ñ", count: 600)))
    }

    @Test func theTabletsFilesThroughTheServer() async throws {
        // What ADBFileSystem does with a direct connection: the file channel for whole files,
        // `dd` for a read from inside one, and one shell command to put an upload in place.
        let folder = pretend.folder
        pretend.shell = { command in
            if command.hasPrefix("rm -f -- ") { return ("", "", 0) }
            // commitCommand ends in: mv -- '<part>' '<path>'
            let quoted = command.components(separatedBy: " && mv -- ").last?.components(separatedBy: "' '") ?? []
            guard quoted.count == 2 else { return ("", "unknown", 1) }
            let part = String(quoted[0].dropFirst()), path = String(quoted[1].dropLast())
            do {
                try? FileManager.default.removeItem(atPath: folder.path + path)
                try FileManager.default.moveItem(atPath: folder.path + part, toPath: folder.path + path)
                return ("", "", 0)
            } catch { return ("", "mv failed", 1) }
        }
        let bytes = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 / 251) })
        pretend.output = { command in
            // readCommand: dd if='<path>' bs=65536 skip=N
            guard let skip = command.components(separatedBy: "skip=").last?.split(separator: " ").first.flatMap({ Int($0) }) else { return Data() }
            return Data(bytes.dropFirst(skip * 65_536))
        }
        let fs = ADBFileSystem(adb: ADB(path: "/nonexistent/adb", server: pretend.server), serial: "TAB1")
        let source = Chunks(bytes, size: 70_000)
        try await fs.write("/sdcard/video.bin") { source.next() }
        #expect(try Data(contentsOf: pretend.url("/sdcard/video.bin")) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: pretend.url("/sdcard").path) == ["video.bin"])
        func read(from offset: Int64, length: Int64?) async throws -> Data {
            let got = Chunks(Data(), size: 1)
            try await fs.read("/sdcard/video.bin", from: offset, length: length) { got.append($0) }
            return got.all
        }
        #expect(try await read(from: 0, length: nil) == bytes)
        #expect(try await read(from: 0, length: 10) == bytes.prefix(10))
        #expect(try await read(from: 70_001, length: 131_072) == bytes[70_001..<201_073])
        #expect(try await read(from: 299_990, length: 10) == bytes[299_990...])
        await #expect(throws: FileError.self) { _ = try await read(from: 299_990, length: 50) }
        await #expect(throws: FileError.self) { _ = try await read(from: 0, length: 300_001) }
        // A refused name leaves nothing, and asks for the part to be removed.
        let text = Chunks(Data("x".utf8), size: 10)
        await #expect(throws: FileError.self) { try await fs.write("/sdcard/a:b.txt") { text.next() } }
        #expect(pretend.commands.last?.hasPrefix("rm -f -- '/sdcard/.a:b.txt.androidfiles-part-") == true)
    }
}
