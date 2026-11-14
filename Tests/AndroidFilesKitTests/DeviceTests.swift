import Foundation
import Testing
@testable import AndroidFilesKit

/// Runs against the tablet plugged in now, only when ANDROIDFILES_DEVICE=1:
///   ANDROIDFILES_DEVICE=1 tools/test.sh --filter Device
/// Everything happens in a new /sdcard/AndroidFiles-e2e-<id> folder, deleted at the end.
@Suite("Device (real tablet over adb)", .enabled(if: ProcessInfo.processInfo.environment["ANDROIDFILES_DEVICE"] == "1"),
       .serialized)
struct DeviceTests {
    /// tools/fake-adb (a Docker container with toybox) stands in for the tablet. It takes any name
    /// and copies too fast to cancel, so those checks need the real one.
    static let pretend = ProcessInfo.processInfo.environment["ADB_PATH"]?.hasSuffix("fake-adb") == true

    let adb: ADB
    var direct: Bool { fs.adb.server != nil }
    let fs: ADBFileSystem
    let remote: String

    init() async throws {
        let path = try #require(ADB.locate(), "adb is not installed")
        adb = ADB(path: path)
        let device = try #require(try await adb.devices().first { $0.state == .ready }, "no tablet with USB debugging allowed")
        // The way the app reaches it: directly through adb's server when that answers (the real tablet).
        fs = ADBFileSystem(adb: await adb.direct(for: device.serial), serial: device.serial)
        let id = UUID().uuidString.prefix(8)
        remote = "/sdcard/AndroidFiles-e2e-\(id)"
        try await fs.makeFolder(remote)
    }

    /// Runs a test body, then removes the sandbox folder even when it threw.
    private func sandboxed(_ body: () async throws -> Void) async throws {
        do { try await body() } catch { await cleanUp(); throw error }
        await cleanUp()
    }

    private func cleanUp() async {
        try? await fs.delete(remote)
    }

    @Test func nameAndListing() async throws {
        try await sandboxed {
            let name = await adb.deviceName(fs.serial)
            #expect(name?.isEmpty == false)
            let top = try await fs.list("/sdcard")
            #expect(top.contains { $0.name == "Download" && $0.isFolder })
            await #expect(throws: FileError.self) { try await fs.list("/data") }
        }
    }

    /// S-016: the share Finder mounts, on the tablet's own rules for names.
    @Test func theFinderShareOnTheTablet() async throws {
        try await sandboxed {
            let share = WebDAVShare(files: fs, content: fs, root: remote, prefix: "/tok")
            func send(_ method: String, _ target: String, _ headers: [String: String] = [:], body: String? = nil) async throws -> Int {
                let pieces = Chunks(Data((body ?? "").utf8), size: 1000)
                return try await share.handle(DAVRequest(method: method, target: "/tok" + target, headers: headers) { pieces.next() }).status
            }
            func names() async throws -> [String] { try await fs.list(remote).map(\.name).sorted() }
            func content(_ name: String) async throws -> String {
                let got = Chunks(Data(), size: 1)
                try await fs.read("\(remote)/\(name)", from: 0, length: nil) { got.append($0) }
                return String(decoding: got.all, as: UTF8.self)
            }

            // What Finder does for a new file: empty PUT, LOCK, PUT, UNLOCK.
            let v1 = try await send("PUT", "/Informe%20a%C3%B1o.txt")
            #expect(v1 == 201)
            let v2 = try await send("LOCK", "/Informe%20a%C3%B1o.txt")
            #expect(v2 == 200)
            let v3 = try await send("PUT", "/Informe%20a%C3%B1o.txt", body: "original")
            #expect(v3 == 204)
            let v4 = try await names()
            #expect(v4 == ["Informe año.txt"])
            let v5 = try await content("Informe año.txt")
            #expect(v5 == "original")
            let v6 = try await send("MKCOL", "/Fotos")
            #expect(v6 == 201)
            let v7 = try await send("PROPFIND", "/", ["depth": "1"])
            #expect(v7 == 207)

            if !Self.pretend {
                // The tablet ignores case: the other spelling is the same file, and stays whole.
                let v8 = try await send("PROPFIND", "/informe%20A%C3%B1o.txt", ["depth": "0"])
                #expect(v8 == 207)
                let v9 = try await send("LOCK", "/INFORME%20A%C3%91O.TXT")
                #expect(v9 == 200)
                let v10 = try await content("Informe año.txt")
                #expect(v10 == "original")
                let v11 = try await send("PUT", "/draft.txt", body: "draft")
                #expect(v11 == 201)
                let v12 = try await send("MOVE", "/draft.txt", ["destination": "/tok/INFORME%20a%C3%B1o.txt", "overwrite": "F"])
                #expect(v12 == 412)
                let v13 = try await content("Informe año.txt")
                #expect(v13 == "original")
                // Changing only the case renames.
                let v14 = try await send("MOVE", "/draft.txt", ["destination": "/tok/Draft.txt", "overwrite": "F"])
                #expect(v14 == 201)
                let v15 = try await names()
                #expect(v15 == ["Draft.txt", "Fotos", "Informe año.txt"])
                let v16 = try await content("Draft.txt")
                #expect(v16 == "draft")
                let v17 = try await send("DELETE", "/Draft.txt")
                #expect(v17 == 204)
                // A name the tablet refuses.
                let v18 = try await send("PUT", "/a%3Ab.txt", body: "x")
                #expect(v18 == 403)
            }

            let v19 = try await send("MOVE", "/Informe%20a%C3%B1o.txt", ["destination": "/tok/Fotos/Informe%20a%C3%B1o.txt"])
            #expect(v19 == 201)
            let v20 = try await send("GET", "/Fotos/Informe%20a%C3%B1o.txt")
            #expect(v20 == 200)
            let v21 = try await send("DELETE", "/Fotos")
            #expect(v21 == 204)
            let v22 = try await names()
            #expect(v22 == [])
        }
    }

    /// S-016: what the Finder volume asks of the tablet.
    @Test func streamsFilesBothWaysForTheFinderVolume() async throws {
        try await sandboxed {
            // 300 000 bytes whose value depends on the position, so a wrong offset shows.
            let bytes = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 / 251) })
            let path = "\(remote)/it's a stream ñ.bin"
            let source = Chunks(bytes, size: 70_000)
            try await fs.write(path) { source.next() }
            #expect(try await fs.list(remote).map(\.name) == ["it's a stream ñ.bin"])
            #expect(try await fs.size(path) == 300_000)

            func read(from offset: Int64, length: Int64?) async throws -> Data {
                let got = Chunks(Data(), size: 1)
                try await fs.read(path, from: offset, length: length) { got.append($0) }
                return got.all
            }
            #expect(try await read(from: 0, length: nil) == bytes)
            #expect(try await read(from: 0, length: 300_000) == bytes)
            #expect(try await read(from: 5, length: 10) == bytes[5..<15])
            #expect(try await read(from: 70_001, length: 131_072) == bytes[70_001..<201_073])
            #expect(try await read(from: 299_990, length: 10) == bytes[299_990...])
            await #expect(throws: FileError.self) { _ = try await read(from: 299_990, length: 50) }

            // Replace, and an empty file.
            let small = Chunks(Data("new".utf8), size: 10)
            try await fs.write(path) { small.next() }
            #expect(try await read(from: 0, length: nil) == Data("new".utf8))
            try await fs.write("\(remote)/empty.txt") { nil }
            #expect(try await fs.size("\(remote)/empty.txt") == 0)

            // An upload that breaks keeps the old file and leaves no part file.
            struct Broken: Error {}
            await #expect(throws: Broken.self) { try await fs.write(path) { throw Broken() } }
            #expect(try await read(from: 0, length: nil) == Data("new".utf8))
            #expect(try await fs.list(remote).map(\.name).sorted() == ["empty.txt", "it's a stream ñ.bin"])
            // A name the tablet refuses fails, and leaves nothing.
            if !Self.pretend {
                await #expect(throws: FileError.self) { try await fs.write("\(remote)/a:b.txt") { nil } }
                #expect(try await fs.list(remote).count == 2)
            }

            let space = try #require(await fs.space("/sdcard"))
            #expect(space.free > 0 && space.used > 0)
        }
    }

    /// Load and speed through the share over HTTP, as the mounted volume asks it, only with
    /// ANDROIDFILES_STRESS=1 too (about a minute; STRESS_MB sets the big file's size, default 200).
    /// Prints "SPEED ..." lines.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ANDROIDFILES_STRESS"] == "1"), .timeLimit(.minutes(20)))
    func loadThroughTheShare() async throws {
        try await sandboxed {
            let share = WebDAVShare(files: fs, content: fs, root: remote, prefix: "/tok")
            let server = try await HTTPServer(handler: share.handler)
            defer { server.stop() }
            let base = "http://127.0.0.1:\(server.port)/tok"
            let work = URL(fileURLWithPath: "/tmp/AndroidFiles-stress-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            let session = URLSession(configuration: .ephemeral)
            @Sendable func call(_ method: String, _ path: String, _ headers: [String: String] = [:], body: Data? = nil) async throws -> (Int, Data) {
                var request = URLRequest(url: URL(string: base + path)!)
                request.httpMethod = method
                for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
                let (data, response) = if let body { try await session.upload(for: request, from: body) }
                    else { try await session.data(for: request) }
                return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
            }
            /// What Finder sends for one new file.
            @Sendable func finderCopy(_ path: String, _ data: Data) async throws -> Bool {
                let steps = [try await call("PROPFIND", path, ["Depth": "0"]).0, try await call("PUT", path, body: Data()).0,
                             try await call("LOCK", path).0, try await call("PROPFIND", path, ["Depth": "0"]).0,
                             try await call("PUT", path, body: data).0, try await call("UNLOCK", path).0,
                             try await call("PROPFIND", path, ["Depth": "0"]).0]
                if steps != [404, 201, 200, 207, 204, 204, 207] { print("STEPS \(path): \(steps)") }
                return steps == [404, 201, 200, 207, 204, 204, 207]
            }
            func content(_ i: Int) -> Data { Data("file \(i) ".utf8) + Data(repeating: UInt8(truncatingIfNeeded: i), count: 1000 + i * 37 % 5000) }
            func seconds(_ from: Date) -> String { String(format: "%.1f", Date.now.timeIntervalSince(from)) }
            let link = direct ? "direct" : "adb program"

            // 1. Many small files, one after another.
            #expect(try await call("MKCOL", "/many").0 == 201)
            var started = Date.now
            var allOK = true
            for i in 0..<200 { allOK = try await finderCopy("/many/photo%20\(i).jpg", content(i)) && allOK }
            #expect(allOK)
            print("SPEED \(link): 200 small files one by one in \(seconds(started)) s (\(Int(Date.now.timeIntervalSince(started) * 5)) ms each)")
            // 2. And six at a time, as Finder does with several connections.
            #expect(try await call("MKCOL", "/parallel").0 == 201)
            started = .now
            let parallelOK = try await withThrowingTaskGroup(of: Bool.self) { group in
                for lane in 0..<6 {
                    group.addTask {
                        var ok = true
                        for i in stride(from: lane, to: 300, by: 6) { ok = try await finderCopy("/parallel/doc%20\(i).txt", Data("file \(i) ".utf8) + Data(repeating: UInt8(truncatingIfNeeded: i), count: 1000 + i * 37 % 5000)) && ok }
                        return ok
                    }
                }
                var ok = true
                for try await result in group { ok = ok && result }
                return ok
            }
            #expect(parallelOK)
            print("SPEED \(link): 300 small files six at a time in \(seconds(started)) s")
            // Every one is on the tablet, whole.
            let many = try await fs.list("\(remote)/many"), parallel = try await fs.list("\(remote)/parallel")
            #expect(many.count == 200 && parallel.count == 300)
            #expect(many.allSatisfy { entry in Int(entry.name.dropFirst(6).dropLast(4)).map { entry.size == Int64(content($0).count) } == true })
            #expect(parallel.allSatisfy { entry in Int(entry.name.dropFirst(4).dropLast(4)).map { entry.size == Int64(content($0).count) } == true })
            for entry in parallel where Int(entry.name.dropFirst(4).dropLast(4)).map({ entry.size == Int64(content($0).count) }) != true {
                print("WRONG \(entry.name): \(entry.size) bytes")
            }
            for i in [0, 57, 199] { #expect(try await call("GET", "/many/photo%20\(i).jpg").1 == content(i)) }
            for i in [5, 123, 299] { #expect(try await call("GET", "/parallel/doc%20\(i).txt").1 == content(i)) }
            // The share's own picture of the folder is the tablet's.
            let listed = String(decoding: try await call("PROPFIND", "/many/", ["Depth": "1"]).1, as: UTF8.self)
            #expect(listed.components(separatedBy: "<D:response>").count - 1 == 201)
            // No part or stray file anywhere.
            let stray = try await adb.shell(fs.serial, "find \(shellQuote(remote)) -name '.*' | wc -l")
            #expect(stray.text.trimmingCharacters(in: .whitespacesAndNewlines) == "0")

            // 3. A big file up and down, byte for byte.
            let megabytes = Int(ProcessInfo.processInfo.environment["STRESS_MB"] ?? "") ?? 200
            let big = work.appending(path: "big.bin")
            FileManager.default.createFile(atPath: big.path, contents: nil)
            let handle = try FileHandle(forWritingTo: big)
            var block = Data(count: 1 << 20)
            for i in 0..<megabytes {
                block.withUnsafeMutableBytes { bytes in
                    var x = UInt64(i) &* 0x9E3779B97F4A7C15 | 1
                    for j in stride(from: 0, to: 1 << 20, by: 8) {
                        x ^= x << 13; x ^= x >> 7; x ^= x << 17
                        bytes.storeBytes(of: x, toByteOffset: j, as: UInt64.self)
                    }
                }
                try handle.write(contentsOf: block)
            }
            try handle.close()
            func sum(_ url: URL) throws -> String {
                let result = Process()
                result.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
                result.arguments = ["-a", "256", url.path]
                let pipe = Pipe()
                result.standardOutput = pipe
                try result.run()
                let out = pipe.fileHandleForReading.readDataToEndOfFile()
                result.waitUntilExit()
                return String(String(decoding: out, as: UTF8.self).prefix(64))
            }
            #expect(try await call("PUT", "/big%20%C3%B1.bin", body: Data()).0 == 201)
            started = .now
            var put = URLRequest(url: URL(string: base + "/big%20%C3%B1.bin")!)
            put.httpMethod = "PUT"
            let (_, putResponse) = try await session.upload(for: put, fromFile: big)
            #expect((putResponse as? HTTPURLResponse)?.statusCode == 204)
            var took = Date.now.timeIntervalSince(started)
            print("SPEED \(link): \(megabytes) MB to the tablet in \(seconds(started)) s (\(String(format: "%.1f", Double(megabytes) / took)) MB/s)")
            #expect(try await fs.list(remote).first { $0.name == "big ñ.bin" }?.size == Int64(megabytes) << 20)
            started = .now
            let (downloaded, _) = try await session.download(from: URL(string: base + "/big%20%C3%B1.bin")!)
            took = Date.now.timeIntervalSince(started)
            print("SPEED \(link): \(megabytes) MB from the tablet in \(seconds(started)) s (\(String(format: "%.1f", Double(megabytes) / took)) MB/s)")
            #expect(try sum(downloaded) == sum(big))
            // Reads from inside it.
            let whole = try FileHandle(forReadingFrom: big)
            for offset in [1, 65_536, 1_000_003, (megabytes << 20) - 4_096] {
                try whole.seek(toOffset: UInt64(offset))
                let expected = try whole.read(upToCount: 4_096)
                let got = try await call("GET", "/big%20%C3%B1.bin", ["Range": "bytes=\(offset)-\(offset + 4_095)"])
                #expect(got.0 == 206 && got.1 == expected, "offset \(offset)")
            }
            // Replacing it with a small one, then removing everything.
            #expect(try await call("PUT", "/big%20%C3%B1.bin", body: Data("small".utf8)).0 == 204)
            #expect(try await call("GET", "/big%20%C3%B1.bin").1 == Data("small".utf8))
            started = .now
            for folder in ["/many", "/parallel"] { #expect(try await call("DELETE", folder).0 == 204) }
            #expect(try await call("DELETE", "/big%20%C3%B1.bin").0 == 204)
            #expect(try await fs.list(remote).isEmpty)
        }
    }

    /// Wi-Fi with the real tablet, only with ANDROIDFILES_WIFI=1 too: adbd restarts twice
    /// (to Wi-Fi and back to USB with `adb usb`), so other tests must not run beside it.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ANDROIDFILES_WIFI"] == "1"))
    func wifiRoundTrip() async throws {
        try await sandboxed {
            let address = try await adb.switchToWiFi(fs.serial)
            let wifi = ADBFileSystem(adb: adb, serial: address)
            let text = Chunks(Data("w".utf8), size: 10)
            try await wifi.write("\(remote)/wifi.txt") { text.next() }
            #expect(try await wifi.list(remote).map(\.name).contains("wifi.txt"))
            // Back to USB only: the tablet stops listening on the network.
            await adb.disconnect(address)
            for _ in 0..<20 where (try? await adb.devices().contains { $0.serial == fs.serial && $0.state == .ready }) != true {
                try await Task.sleep(for: .milliseconds(500))
            }
            #expect(try await adb.devices().contains { $0.serial == fs.serial && $0.state == .ready }, "USB is back")
        }
    }
}

/// Bytes handed out or collected in pieces.
final class Chunks: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data
    private let size: Int

    init(_ data: Data, size: Int) {
        self.data = data
        self.size = size
    }

    func next() -> Data? {
        lock.withLock {
            guard !data.isEmpty else { return nil }
            let piece = Data(data.prefix(size))
            data = Data(data.dropFirst(piece.count))
            return piece
        }
    }

    func append(_ piece: Data) { lock.withLock { data.append(piece) } }
    var all: Data { lock.withLock { data } }
}
