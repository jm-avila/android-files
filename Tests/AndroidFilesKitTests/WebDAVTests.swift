import Foundation
import Testing
@testable import AndroidFilesKit

/// S-016: the tablet as a volume in Finder. The share is driven the way macOS drives it,
/// on a pretend tablet folder in /tmp.
@Suite("WebDAV share (S-016)")
struct WebDAVTests {
    let box: Sandbox
    let share: WebDAVShare

    init() throws {
        box = try Sandbox()
        share = WebDAVShare(files: box.device, content: box.device, root: "/sdcard", prefix: "/tok")
    }

    /// A body in pieces, like an upload arriving.
    final class Pieces: @unchecked Sendable {
        private var left: [Data]
        private let lock = NSLock()
        init(_ texts: [String]) { left = texts.map { Data($0.utf8) } }
        func next() -> Data? { lock.withLock { left.isEmpty ? nil : left.removeFirst() } }
    }

    func send(_ method: String, _ target: String, _ headers: [String: String] = [:], body: [String] = []) async throws -> DAVResponse {
        let pieces = Pieces(body)
        return try await share.handle(DAVRequest(method: method, target: target, headers: headers) { pieces.next() })
    }

    func text(_ response: DAVResponse) async throws -> String {
        switch response.body {
        case .none: return ""
        case .data(let data): return String(decoding: data, as: UTF8.self)
        case .stream(_, let produce):
            let collected = Collected()
            try await produce { collected.add($0) }
            return String(decoding: collected.data, as: UTF8.self)
        }
    }

    final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        func add(_ data: Data) { lock.withLock { bytes.append(data) } }
        var data: Data { lock.withLock { bytes } }
    }

    @Test func listsAFolderWithSizesAndHidesFindersOwnFiles() async throws {
        try box.write(.device, "/sdcard/photo one.jpg", "12345")
        try box.write(.device, "/sdcard/._photo one.jpg", "junk")
        try box.write(.device, "/sdcard/.DS_Store", "junk")
        let response = try await send("PROPFIND", "/tok/", ["depth": "1"])
        let xml = try await text(response)
        #expect(response.status == 207)
        #expect(xml.contains("<D:href>/tok/</D:href>"))
        #expect(xml.contains("<D:href>/tok/photo%20one.jpg</D:href>"))
        #expect(xml.contains("<D:getcontentlength>5</D:getcontentlength>"))
        #expect(xml.contains("<D:href>/tok/Download/</D:href>"))
        #expect(xml.contains("quota-available-bytes"))
        #expect(!xml.contains("._photo") && !xml.contains("DS_Store"))
    }

    @Test func depthZeroDescribesOnlyTheItemAndMissingIs404() async throws {
        try box.write(.device, "/sdcard/a.txt")
        let xml = try await text(try await send("PROPFIND", "/tok/Download", ["depth": "0"]))
        #expect(xml.contains("/tok/Download/") && !xml.contains("a.txt"))
        #expect(try await send("PROPFIND", "/tok/nope", ["depth": "0"]).status == 404)
    }

    @Test func nothingOutsideTheShareIsReachable() async throws {
        #expect(try await send("PROPFIND", "/other/").status == 404)
        #expect(try await send("PROPFIND", "/tok/../mac").status == 404)
        #expect(try await send("PROPFIND", "/tok/%2e%2e/mac").status == 404)
        #expect(try await send("PROPFIND", "/tok/a%2Fb").status == 404)
        #expect(await share.resolve("/tok/Download/a%20b.txt?x=1") == "/sdcard/Download/a b.txt")
        #expect(await share.resolve("http://127.0.0.1:9/tok/Download") == "/sdcard/Download")
        #expect(await share.resolve("http://127.0.0.1:9/tokens") == nil)
    }

    @Test func readsAFileWholeAndInRanges() async throws {
        try box.write(.device, "/sdcard/a.txt", "0123456789")
        let whole = try await send("GET", "/tok/a.txt")
        #expect(whole.status == 200 && whole.headers["Content-Length"] == "10")
        #expect(try await text(whole) == "0123456789")
        let part = try await send("GET", "/tok/a.txt", ["range": "bytes=2-5"])
        #expect(part.status == 206 && part.headers["Content-Range"] == "bytes 2-5/10")
        #expect(try await text(part) == "2345")
        #expect(try await text(try await send("GET", "/tok/a.txt", ["range": "bytes=7-"])) == "789")
        let head = try await send("HEAD", "/tok/a.txt")
        #expect(head.headers["Content-Length"] == "10")
        if case .none = head.body {} else { Issue.record("HEAD sent a body") }
        #expect(try await send("GET", "/tok/nope.txt").status == 404)
    }

    @Test func rangesAreParsed() {
        #expect(WebDAVShare.range("bytes=0-99", size: 10)! == (0, 10))
        #expect(WebDAVShare.range("bytes=-3", size: 10)! == (7, 3))
        #expect(WebDAVShare.range("bytes=10-", size: 10) == nil)
        #expect(WebDAVShare.range("bytes=-50", size: 0) == nil)
        #expect(WebDAVShare.range("bytes=0-1,4-5", size: 10) == nil)
        #expect(WebDAVShare.range(nil, size: 10) == nil)
    }

    @Test func writesANewFileAndReplacesOne() async throws {
        #expect(try await send("PUT", "/tok/Download/new.txt", body: ["hello ", "world"]).status == 201)
        #expect(box.read(.device, "/sdcard/Download/new.txt") == "hello world")
        #expect(try await send("PUT", "/tok/Download/new.txt", body: ["again"]).status == 204)
        #expect(box.read(.device, "/sdcard/Download/new.txt") == "again")
        #expect(try await box.names(.device, "/sdcard/Download") == ["new.txt"])
        #expect(try await send("PUT", "/tok/Missing/new.txt", body: ["x"]).status == 409)
        #expect(try await send("PUT", "/tok/Download", body: ["x"]).status == 405)
    }

    @Test func aBrokenUploadLeavesNoFileAndKeepsTheOldOne() async throws {
        try box.write(.device, "/sdcard/Download/keep.txt", "old")
        struct Broken: Error {}
        let request = DAVRequest(method: "PUT", target: "/tok/Download/keep.txt") { throw Broken() }
        await #expect(throws: Broken.self) { try await share.handle(request) }
        #expect(box.read(.device, "/sdcard/Download/keep.txt") == "old")
        #expect(try await box.names(.device, "/sdcard/Download") == ["keep.txt"])
    }

    @Test func namesAndroidRefusesAreRefused() async throws {
        try box.write(.device, "/sdcard/a.txt")
        #expect(try await send("PUT", "/tok/a%3Ab.txt", body: ["x"]).status == 403)
        #expect(try await send("MKCOL", "/tok/what%3F").status == 403)
        #expect(try await send("MOVE", "/tok/a.txt", ["destination": "http://127.0.0.1:9/tok/a%2Ab.txt"]).status == 403)
    }

    @Test func findersOwnFilesStayOffTheTablet() async throws {
        try box.write(.device, "/sdcard/a.txt")
        #expect(try await send("PUT", "/tok/._a.txt", body: ["attrs"]).status == 201)
        #expect(try await send("PUT", "/tok/.DS_Store", body: ["store"]).status == 201)
        #expect(try await box.names(.device, "/sdcard") == ["Download", "a.txt"])
        #expect(try await text(try await send("GET", "/tok/._a.txt")) == "attrs")
        #expect(try await text(try await send("PROPFIND", "/tok/", ["depth": "1"])).contains("/tok/._a.txt"))
        // The attributes follow a renamed file and go with a deleted one.
        #expect(try await send("MOVE", "/tok/a.txt", ["destination": "/tok/b.txt"]).status == 201)
        #expect(try await send("GET", "/tok/._a.txt").status == 404)
        #expect(try await text(try await send("GET", "/tok/._b.txt")) == "attrs")
        #expect(try await send("DELETE", "/tok/b.txt").status == 204)
        #expect(try await send("GET", "/tok/._b.txt").status == 404)
    }

    @Test func deletesMakesFoldersMovesAndCopies() async throws {
        try box.write(.device, "/sdcard/a.txt", "A")
        try box.write(.device, "/sdcard/b.txt", "B")
        #expect(try await send("MKCOL", "/tok/New").status == 201)
        #expect(try await send("MKCOL", "/tok/New").status == 405)
        #expect(try await send("MKCOL", "/tok/Missing/New").status == 409)
        #expect(try await send("COPY", "/tok/a.txt", ["destination": "/tok/New/a.txt"]).status == 201)
        #expect(box.read(.device, "/sdcard/New/a.txt") == "A" && box.read(.device, "/sdcard/a.txt") == "A")
        #expect(try await send("MOVE", "/tok/b.txt", ["destination": "/tok/New/a.txt", "overwrite": "F"]).status == 412)
        #expect(try await send("MOVE", "/tok/b.txt", ["destination": "/tok/New/a.txt"]).status == 204)
        #expect(box.read(.device, "/sdcard/New/a.txt") == "B" && box.read(.device, "/sdcard/b.txt") == nil)
        #expect(try await send("MOVE", "/tok/New", ["destination": "/tok/New/Inside"]).status == 403)
        #expect(try await send("DELETE", "/tok/New").status == 204)
        #expect(try await send("DELETE", "/tok/New").status == 404)
        #expect(try await send("DELETE", "/tok/").status == 403)
        #expect(try await box.names(.device, "/sdcard") == ["Download", "a.txt"])
    }

    /// A tablet that refuses moves onto `refuse`.
    struct StubbornMoves: FileSystem {
        let base: LocalFileSystem
        let refuse: String
        var deletesPermanently: Bool { true }
        func list(_ folder: String) async throws -> [FileEntry] { try await base.list(folder) }
        func exists(_ path: String) async throws -> Bool { try await base.exists(path) }
        func makeFolder(_ path: String) async throws { try await base.makeFolder(path) }
        func move(_ path: String, to: String) async throws {
            if to == refuse && !FilePath.name(path).hasPrefix(".") { throw FileError("refused") }
            try await base.move(path, to: to)
        }
        func copy(_ path: String, to: String) async throws { try await base.copy(path, to: to) }
        func delete(_ path: String) async throws { try await base.delete(path) }
        func size(_ path: String) async throws -> Int64 { try await base.size(path) }
    }

    @Test func aFailedReplaceKeepsTheFileItWasGoingToReplace() async throws {
        try box.write(.device, "/sdcard/new.txt", "new")
        try box.write(.device, "/sdcard/doc.txt", "old")
        let stubborn = WebDAVShare(files: StubbornMoves(base: box.device, refuse: "/sdcard/doc.txt"), content: box.device,
                                   root: "/sdcard", prefix: "/tok")
        let response = try await stubborn.handle(DAVRequest(method: "MOVE", target: "/tok/new.txt", headers: ["destination": "/tok/doc.txt"]))
        #expect(response.status == 403)
        #expect(box.read(.device, "/sdcard/doc.txt") == "old" && box.read(.device, "/sdcard/new.txt") == "new")
        #expect(try await box.names(.device, "/sdcard") == ["Download", "doc.txt", "new.txt"])
    }

    /// The Mac's own disk takes either form for the same file, so the bytes of the names are
    /// checked on the pretend tablet of tools/volume-stress.sh (Linux, where the forms differ).
    @Test func accentedNamesAreTheSameNameInEitherForm() async throws {
        let composed = "ñandú.txt", decomposed = "ñandú.txt".decomposedStringWithCanonicalMapping
        #expect(composed.utf8.count != decomposed.utf8.count)
        func url(_ name: String) -> String { "/tok/" + name.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! }
        // macOS creates it in its decomposed form: the tablet gets the composed one.
        #expect(try await send("PUT", url("Fotos de España".decomposedStringWithCanonicalMapping) + "/x.txt", body: ["x"]).status == 409)
        #expect(try await send("MKCOL", url("España".decomposedStringWithCanonicalMapping)).status == 201)
        #expect(try await send("PUT", url("España".decomposedStringWithCanonicalMapping) + "/" + String(url(decomposed).dropFirst(5)), body: ["hola"]).status == 201)
        #expect(box.read(.device, "/sdcard/España/\(composed)") == "hola")
        // Found again either way.
        for name in [composed, decomposed] {
            #expect(try await text(try await send("GET", url("España") + "/" + String(url(name).dropFirst(5)))) == "hola")
        }
        // A name the tablet already holds decomposed is used as it is.
        try box.write(.device, "/sdcard/\(decomposed)", "viejo")
        try await Task.sleep(for: .seconds(2.1))
        #expect(try await text(try await send("GET", url(composed))) == "viejo")
        #expect(try await send("PUT", url(composed), body: ["nuevo"]).status == 204)
        #expect(box.read(.device, "/sdcard/\(decomposed)") == "nuevo")
        #expect(try await send("MOVE", url(decomposed), ["destination": url("camión.txt".decomposedStringWithCanonicalMapping)]).status == 201)
        #expect(box.read(.device, "/sdcard/camión.txt") == "nuevo")
    }

    @Test func unfinishedUploadsAreHiddenAndGoAfterADay() async throws {
        try box.write(.device, "/sdcard/Download/.video.mp4.androidfiles-part-1A2B3C4D", "half")
        try box.write(.device, "/sdcard/Download/.old.mp4.androidfiles-part-FFFF0000", "half")
        try box.write(.device, "/sdcard/Download/.keep.part-xyz", "mine")
        try box.write(.device, "/sdcard/Download/.backup.part-20240101", "mine too")
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-900_000)],
                                              ofItemAtPath: box.device.url("/sdcard/Download/.backup.part-20240101").path)
        try box.write(.device, "/sdcard/Download/.doc.txt.old-1A2B3C4D", "the only copy")
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-90_000)],
                                              ofItemAtPath: box.device.url("/sdcard/Download/.old.mp4.androidfiles-part-FFFF0000").path)
        let xml = try await text(try await send("PROPFIND", "/tok/Download/", ["depth": "1"]))
        #expect(!xml.contains("part-1A2B3C4D") && !xml.contains("part-FFFF0000") && xml.contains(".backup.part-20240101"))
        #expect(xml.contains(".keep.part-xyz") && xml.contains(".doc.txt.old-1A2B3C4D"))
        #expect(try await box.names(.device, "/sdcard/Download") == [".backup.part-20240101", ".doc.txt.old-1A2B3C4D", ".keep.part-xyz", ".video.mp4.androidfiles-part-1A2B3C4D"])
        #expect(WebDAVShare.isPart(".a.androidfiles-part-0123ABCD") && !WebDAVShare.isPart("a.androidfiles-part-0123ABCD") && !WebDAVShare.isPart(".a.part-01234567"))
    }

    /// A tablet that stops answering: every listing fails, as when adb drops out.
    final class Flaky: FileSystem, @unchecked Sendable {
        let base: LocalFileSystem
        var down = false
        init(_ base: LocalFileSystem) { self.base = base }
        var deletesPermanently: Bool { true }
        private func check() throws { if down { throw FileError("device offline") } }
        func list(_ folder: String) async throws -> [FileEntry] { try check(); return try await base.list(folder) }
        func exists(_ path: String) async throws -> Bool { down ? false : try await base.exists(path) }
        func makeFolder(_ path: String) async throws { try check(); try await base.makeFolder(path) }
        func move(_ path: String, to: String) async throws { try check(); try await base.move(path, to: to) }
        func copy(_ path: String, to: String) async throws { try check(); try await base.copy(path, to: to) }
        func delete(_ path: String) async throws { try check(); try await base.delete(path) }
        func size(_ path: String) async throws -> Int64 { try await base.size(path) }
    }

    @Test func aTabletThatStopsAnsweringIsNotTakenForMissingFiles() async throws {
        try box.write(.device, "/sdcard/Download/doc.txt", "precious")
        let flaky = Flaky(box.device)
        let share = WebDAVShare(files: flaky, content: box.device, root: "/sdcard", prefix: "/tok")
        flaky.down = true
        for method in ["PROPFIND", "LOCK", "GET", "DELETE", "MKCOL"] {
            #expect(try await share.handle(DAVRequest(method: method, target: "/tok/Download/doc.txt")).status == 503, "\(method)")
        }
        #expect(try await share.handle(DAVRequest(method: "MOVE", target: "/tok/Download/doc.txt", headers: ["destination": "/tok/x.txt"])).status == 503)
        #expect(box.read(.device, "/sdcard/Download/doc.txt") == "precious")
        flaky.down = false
        // A folder that is not there is still a plain "not found".
        #expect(try await share.handle(DAVRequest(method: "PROPFIND", target: "/tok/Nope/doc.txt")).status == 404)
        #expect(try await share.handle(DAVRequest(method: "LOCK", target: "/tok/Download/doc.txt")).status == 200)
        #expect(box.read(.device, "/sdcard/Download/doc.txt") == "precious")
    }

    @Test func namesThatDifferOnlyInCaseAreTheSameItem() async throws {
        try box.write(.device, "/sdcard/Download/Report.pdf", "original")
        // Found, so Finder asks before replacing, and locking it creates nothing over it.
        #expect(try await send("PROPFIND", "/tok/Download/report.pdf", ["depth": "0"]).status == 207)
        #expect(try await send("LOCK", "/tok/Download/report.pdf").status == 200)
        #expect(box.read(.device, "/sdcard/Download/Report.pdf") == "original")
        try box.write(.device, "/sdcard/Download/draft.pdf", "draft")
        try await Task.sleep(for: .seconds(2.1))
        #expect(try await send("MOVE", "/tok/Download/draft.pdf", ["destination": "/tok/Download/REPORT.pdf", "overwrite": "F"]).status == 412)
        #expect(box.read(.device, "/sdcard/Download/Report.pdf") == "original")
        // Changing only the case of a name is a rename.
        #expect(try await send("MOVE", "/tok/Download/draft.pdf", ["destination": "/tok/Download/Draft.pdf", "overwrite": "F"]).status == 201)
        #expect(try await box.names(.device, "/sdcard/Download") == ["Draft.pdf", "Report.pdf"])
        #expect(box.read(.device, "/sdcard/Download/Draft.pdf") == "draft")
    }

    @Test func lockingANewNameMakesAnEmptyFileOnceItIsLetGo() async throws {
        let response = try await send("LOCK", "/tok/Download/fresh.txt")
        #expect(response.status == 201 && response.headers["Lock-Token"]?.hasPrefix("<opaquelocktoken:") == true)
        // It waits for its content: nothing on the tablet yet, but Finder sees it.
        #expect(box.read(.device, "/sdcard/Download/fresh.txt") == nil)
        #expect(try await send("PROPFIND", "/tok/Download/fresh.txt", ["depth": "0"]).status == 207)
        #expect(try await send("LOCK", "/tok/Download/fresh.txt").status == 200)
        #expect(try await send("UNLOCK", "/tok/Download/fresh.txt").status == 204)
        #expect(box.read(.device, "/sdcard/Download/fresh.txt") == "")
        #expect(try await send("OPTIONS", "/tok/").headers["DAV"] == "1, 2")
        #expect(try await send("LOCK", "/tok/Nope/fresh.txt").status == 409)
        #expect(try await send("LOCK", "/tok/Download/a:b.txt").status == 403)
    }

    /// Counts what reaches the tablet, to see that Finder's chatter does not.
    final class Counting: FileSystem, FileContent, @unchecked Sendable {
        let base: LocalFileSystem
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        init(_ base: LocalFileSystem) { self.base = base }
        subscript(_ what: String) -> Int { lock.withLock { counts[what] ?? 0 } }
        private func count(_ what: String) { lock.withLock { counts[what, default: 0] += 1 } }
        func reset() { lock.withLock { counts = [:] } }
        var deletesPermanently: Bool { true }
        func list(_ folder: String) async throws -> [FileEntry] { count("list"); return try await base.list(folder) }
        func exists(_ path: String) async throws -> Bool { count("exists"); return try await base.exists(path) }
        func makeFolder(_ path: String) async throws { count("makeFolder"); try await base.makeFolder(path) }
        func move(_ path: String, to: String) async throws { count("move"); try await base.move(path, to: to) }
        func copy(_ path: String, to: String) async throws { count("copy"); try await base.copy(path, to: to) }
        func delete(_ path: String) async throws { count("delete"); try await base.delete(path) }
        func size(_ path: String) async throws -> Int64 { try await base.size(path) }
        func read(_ path: String, from offset: Int64, length: Int64?, to sink: @Sendable (Data) async throws -> Void) async throws {
            count("read"); try await base.read(path, from: offset, length: length, to: sink)
        }
        func write(_ path: String, from next: @Sendable () async throws -> Data?) async throws { count("write"); try await base.write(path, from: next) }
        func create(_ path: String, holding data: Data) async throws { count("create"); try await base.create(path, holding: data) }
        func space(_ path: String) async -> StorageSpace? { await base.space(path) }
    }

    @Test func aNewFileCostsTheTabletOneWrite() async throws {
        let tablet = Counting(box.device)
        let share = WebDAVShare(files: tablet, content: tablet, root: "/sdcard", prefix: "/tok")
        func send(_ method: String, _ target: String, _ headers: [String: String] = [:], body: [String] = []) async throws -> DAVResponse {
            let pieces = Pieces(body)
            return try await share.handle(DAVRequest(method: method, target: target, headers: headers) { pieces.next() })
        }
        #expect(try await send("PROPFIND", "/tok/Download/", ["depth": "1"]).status == 207)
        tablet.reset()
        // Finder, for each file: is it there, create it empty, lock it, look at it, fill it, let it go, look again.
        for i in 1...40 {
            let file = "/tok/Download/photo%20\(i).jpg"
            #expect(try await send("PROPFIND", file, ["depth": "0"]).status == 404)
            #expect(try await send("PUT", file).status == 201)
            #expect(try await send("LOCK", file).status == 200)
            #expect(try await send("PROPFIND", file, ["depth": "0"]).status == 207)
            #expect(try await send("PUT", file, body: ["picture ", "\(i)"]).status == 204)
            #expect(try await send("UNLOCK", file).status == 204)
            #expect(try await send("PROPFIND", file, ["depth": "0"]).status == 207)
        }
        #expect(tablet["create"] == 40 && tablet["write"] == 0, "one step per file, and none for the empty one")
        #expect(tablet["list"] <= 2 && tablet["exists"] == 0, "the folder is not listed again for every file: \(tablet["list"])")
        let xml = try await text(try await send("PROPFIND", "/tok/Download/", ["depth": "1"]))
        for i in 1...40 { #expect(xml.contains("<D:href>/tok/Download/photo%20\(i).jpg</D:href>")) }
        #expect(xml.components(separatedBy: "<D:response>").count - 1 == 41)
        #expect(xml.contains("<D:getcontentlength>9</D:getcontentlength>") && xml.contains("<D:getcontentlength>10</D:getcontentlength>"))
        #expect(try await box.names(.device, "/sdcard/Download").count == 40)
        #expect(box.read(.device, "/sdcard/Download/photo 17.jpg") == "picture 17")
        // What the share remembers matches the tablet: asked again later, the answer is the same.
        try await Task.sleep(for: .seconds(2.1))
        let again = try await text(try await send("PROPFIND", "/tok/Download/", ["depth": "1"]))
        #expect(again.components(separatedBy: "<D:response>").count - 1 == 41)
        // Removing, moving and new folders are remembered too.
        tablet.reset()
        #expect(try await send("DELETE", "/tok/Download/photo%201.jpg").status == 204)
        #expect(try await send("MKCOL", "/tok/Download/Album").status == 201)
        #expect(try await send("MOVE", "/tok/Download/photo%202.jpg", ["destination": "/tok/Download/Album/two.jpg"]).status == 201)
        #expect(try await send("PROPFIND", "/tok/Download/photo%201.jpg", ["depth": "0"]).status == 404)
        #expect(try await send("PROPFIND", "/tok/Download/photo%202.jpg", ["depth": "0"]).status == 404)
        #expect(try await send("PROPFIND", "/tok/Download/Album/", ["depth": "0"]).status == 207)
        #expect(try await text(try await send("GET", "/tok/Download/Album/two.jpg")) == "picture 2")
        #expect(tablet["list"] <= 2, "\(tablet["list"])")
        #expect(try await box.names(.device, "/sdcard/Download/Album") == ["two.jpg"])
    }

    @Test func anEmptyNewFileWaitsForItsContentAndIsWrittenIfNoneComes() async throws {
        #expect(try await send("PUT", "/tok/Download/a.txt").status == 201)
        #expect(try await send("PUT", "/tok/Download/a.txt").status == 204)
        #expect(box.read(.device, "/sdcard/Download/a.txt") == nil)
        // Finder sees an empty file, alone and in the folder.
        #expect(try await text(try await send("PROPFIND", "/tok/Download/a.txt", ["depth": "0"])).contains("<D:getcontentlength>0</D:getcontentlength>"))
        #expect(try await text(try await send("PROPFIND", "/tok/Download/", ["depth": "1"])).contains("<D:href>/tok/Download/a.txt</D:href>"))
        let got = try await send("GET", "/tok/Download/a.txt")
        #expect(got.status == 200 && got.headers["Content-Length"] == "0")
        // No content came: after a moment the empty file is on the tablet (touch, an empty document).
        try await Task.sleep(for: .seconds(WebDAVShare.pendingLife + 1.6))
        #expect(box.read(.device, "/sdcard/Download/a.txt") == "")
        #expect(try await send("PROPFIND", "/tok/Download/a.txt", ["depth": "0"]).status == 207)

        // Deleted while it waits: it never reaches the tablet.
        #expect(try await send("PUT", "/tok/Download/b.txt").status == 201)
        #expect(try await send("DELETE", "/tok/Download/b.txt").status == 204)
        #expect(try await send("PROPFIND", "/tok/Download/b.txt", ["depth": "0"]).status == 404)
        await share.settle()
        #expect(box.read(.device, "/sdcard/Download/b.txt") == nil)

        // Moved while it waits: it is written, then moved.
        #expect(try await send("PUT", "/tok/Download/c.txt").status == 201)
        #expect(try await send("MOVE", "/tok/Download/c.txt", ["destination": "/tok/Download/d.txt"]).status == 201)
        #expect(box.read(.device, "/sdcard/Download/d.txt") == "" && box.read(.device, "/sdcard/Download/c.txt") == nil)

        // Something moved onto a waiting name takes its place.
        #expect(try await send("PUT", "/tok/full.txt", body: ["full"]).status == 201)
        #expect(try await send("PUT", "/tok/Download/e.txt").status == 201)
        #expect(try await send("MOVE", "/tok/full.txt", ["destination": "/tok/Download/e.txt", "overwrite": "F"]).status == 412)
        #expect(try await send("MOVE", "/tok/full.txt", ["destination": "/tok/Download/e.txt"]).status == 204)
        await share.settle()
        #expect(box.read(.device, "/sdcard/Download/e.txt") == "full")

        // A file that appeared on the tablet under a waiting name is never emptied.
        #expect(try await send("PUT", "/tok/Download/f.txt").status == 201)
        try box.write(.device, "/sdcard/Download/f.txt", "made on the tablet")
        await share.settle()
        #expect(box.read(.device, "/sdcard/Download/f.txt") == "made on the tablet")

        // An empty PUT on a file that is there empties it: that is what was asked.
        #expect(try await send("PUT", "/tok/Download/d.txt", body: ["text"]).status == 204)
        #expect(try await send("PUT", "/tok/Download/d.txt").status == 204)
        #expect(box.read(.device, "/sdcard/Download/d.txt") == "")
        // A folder deleted with a waiting name inside takes the name with it.
        #expect(try await send("MKCOL", "/tok/Gone").status == 201)
        #expect(try await send("PUT", "/tok/Gone/g.txt").status == 201)
        #expect(try await send("DELETE", "/tok/Gone").status == 204)
        await share.settle()
        #expect(try await box.names(.device, "/sdcard").contains("Gone") == false)
    }

    /// A tablet whose writes take a while, so two can overlap.
    final class Slow: FileSystem, FileContent, @unchecked Sendable {
        let base: LocalFileSystem
        init(_ base: LocalFileSystem) { self.base = base }
        var deletesPermanently: Bool { true }
        func list(_ folder: String) async throws -> [FileEntry] { try await base.list(folder) }
        func exists(_ path: String) async throws -> Bool { try await base.exists(path) }
        func makeFolder(_ path: String) async throws { try await base.makeFolder(path) }
        func move(_ path: String, to: String) async throws { try await base.move(path, to: to) }
        func copy(_ path: String, to: String) async throws { try await base.copy(path, to: to) }
        func delete(_ path: String) async throws { try await base.delete(path) }
        func size(_ path: String) async throws -> Int64 { try await base.size(path) }
        func read(_ path: String, from offset: Int64, length: Int64?, to sink: @Sendable (Data) async throws -> Void) async throws {
            try await base.read(path, from: offset, length: length, to: sink)
        }
        func write(_ path: String, from next: @Sendable () async throws -> Data?) async throws { try await base.write(path, from: next) }
        /// The empty file is the slow one: it lands 300 ms after it was asked for.
        func create(_ path: String, holding data: Data) async throws {
            if data.isEmpty { try await Task.sleep(for: .milliseconds(300)) }
            try await base.create(path, holding: data)
        }
        func space(_ path: String) async -> StorageSpace? { nil }
    }

    @Test func contentThatArrivesWhileTheEmptyFileIsBeingWrittenWins() async throws {
        let slow = Slow(box.device)
        let share = WebDAVShare(files: slow, content: slow, root: "/sdcard", prefix: "/tok")
        for round in 0..<5 {
            let target = "/tok/Download/late \(round).txt".replacingOccurrences(of: " ", with: "%20")
            #expect(try await share.handle(DAVRequest(method: "LOCK", target: target)).status == 201)
            // Let go with nothing written: the empty file starts on its slow way...
            let letGo = Task { try await share.handle(DAVRequest(method: "UNLOCK", target: target)).status }
            try await Task.sleep(for: .milliseconds(100))
            // ...and the content comes right behind it.
            let text = Pieces(["the content"])
            #expect([201, 204].contains(try await share.handle(DAVRequest(method: "PUT", target: target) { text.next() }).status))
            #expect(try await letGo.value == 204)
            try await Task.sleep(for: .milliseconds(400))
            #expect(box.read(.device, "/sdcard/Download/late \(round).txt") == "the content")
        }
    }

    /// A body whose bytes take a moment to come, as over a real connection.
    final class LateBody: @unchecked Sendable {
        private let pieces: Pieces
        private let lock = NSLock()
        private var late = true
        init(_ texts: [String]) { pieces = Pieces(texts) }
        func next() async throws -> Data? {
            // Only the first piece is late: the content then lands before a slow empty file would.
            if lock.withLock({ defer { late = false }; return late }) { try await Task.sleep(for: .milliseconds(200)) }
            return pieces.next()
        }
    }

    @Test func anEmptyFileNeverStartsWhileTheContentIsOnItsWay() async throws {
        let slow = Slow(box.device)
        let share = WebDAVShare(files: slow, content: slow, root: "/sdcard", prefix: "/tok")
        for round in 0..<3 {
            let target = "/tok/Download/onway%20\(round).txt"
            #expect(try await share.handle(DAVRequest(method: "LOCK", target: target)).status == 201)
            // The content's request is in, its bytes are not yet...
            let body = LateBody(["the content"])
            let put = Task { try await share.handle(DAVRequest(method: "PUT", target: target) { try await body.next() }).status }
            try await Task.sleep(for: .milliseconds(80))
            // ...when the name is let go and the waiting ones are written.
            #expect(try await share.handle(DAVRequest(method: "UNLOCK", target: target)).status == 204)
            await share.settle()
            #expect([201, 204].contains(try await put.value))
            try await Task.sleep(for: .milliseconds(500))
            #expect(box.read(.device, "/sdcard/Download/onway \(round).txt") == "the content")
        }
    }

    @Test func aNameInAnotherCaseIsListedOnce() async throws {
        #expect(try await send("PROPFIND", "/tok/Download/", ["depth": "1"]).status == 207)
        #expect(try await send("PUT", "/tok/Download/case.txt", body: ["one"]).status == 201)
        #expect(try await send("PUT", "/tok/Download/CASE.txt", body: ["two"]).status == 204)
        let listed = try await text(try await send("PROPFIND", "/tok/Download/", ["depth": "1"])).lowercased()
        #expect(listed.components(separatedBy: "/download/case.txt<").count == 2)
    }

    @Test(arguments: [0, 1, 262_143, 262_144, 262_145, 1_000_000])
    func filesOfEverySizeArriveWhole(size: Int) async throws {
        let tablet = Counting(box.device)
        let share = WebDAVShare(files: tablet, content: tablet, root: "/sdcard", prefix: "/tok")
        let bytes = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ $0 / 253) })
        for (name, piece) in [("new.bin", 65_536), ("new.bin", 100_000), ("other.bin", 300_000)] {
            // The second round replaces the first file: that one goes through the careful write.
            let chunks = Chunks(bytes, size: piece)
            let response = try await share.handle(DAVRequest(method: "PUT", target: "/tok/Download/\(name)") { chunks.next() })
            #expect([201, 204].contains(response.status))
            await share.settle()
            #expect(try Data(contentsOf: box.device.url("/sdcard/Download/\(name)")) == bytes, "\(name) \(piece)")
            let listed = try await share.handle(DAVRequest(method: "PROPFIND", target: "/tok/Download/\(name)", headers: ["depth": "0"]))
            #expect(try await text(listed).contains("<D:getcontentlength>\(size)</D:getcontentlength>"))
        }
        #expect(try await box.names(.device, "/sdcard/Download") == ["new.bin", "other.bin"])
        // Small new files take the one-step way; big ones and replacements the careful one.
        if size > 0 { #expect(tablet["create"] == (size <= 262_144 ? 2 : 0) && tablet["write"] == (size <= 262_144 ? 1 : 3)) }
    }

    @Test func aFileIntoAFolderThatIsNotThereIsRefused() async throws {
        #expect(try await send("PUT", "/tok/Nope/a.txt", body: ["x"]).status == 409)
        #expect(try await send("PUT", "/tok/Nope/a.txt").status == 409)
        #expect(try await send("PUT", "/tok/Download/Nope/deeper/a.txt", body: [String(repeating: "x", count: 400_000)]).status == 409)
        #expect(try await box.names(.device, "/sdcard") == ["Download"])
        #expect(try await box.names(.device, "/sdcard/Download") == [])
    }

    @Test func argumentsReachAProgramByteForByte() async throws {
        let words = ["ñandú € 日本", "can\u{0303}o\u{0301}n", "it's \"q\" $(id) `x` \\n 100%", "línea\ndos", "plain", "ñ bs=65536 skip=3 2>/dev/null\t7"]
        for word in words {
            let result = try await ProcessRunner().run("/usr/bin/printf", ["%s", word])
            #expect(Array(result.stdout) == Array(word.utf8), "\(word)")
        }
        // Several at once, and the exit status still comes through.
        let both = try await ProcessRunner().run("/bin/sh", ["-c", "printf '%s|%s' \"$1\" \"$2\"; exit 7", "sh", "ñ", "ü b"])
        #expect(Array(both.stdout) == Array("ñ|ü b".utf8) && both.status == 7)
    }

    @Test func tabletCommandsForReadingAndSpace() {
        #expect(ADBFileSystem.readCommand("/sdcard/it's.mp4", from: 0) == "cat -- '/sdcard/it'\\''s.mp4' 2>/dev/null")
        #expect(ADBFileSystem.readCommand("/sdcard/a.mp4", from: 200_000) == "dd if='/sdcard/a.mp4' bs=65536 skip=3 2>/dev/null")
        let commit = ADBFileSystem.commitCommand(part: "/sdcard/.a b.part-1", path: "/sdcard/a b", bytes: 42)
        #expect(commit.hasPrefix("i=0; last=; while :; do s=$(stat -c %s -- '/sdcard/.a b.part-1' 2>/dev/null); [ \"$s\" = 42 ] && break; "))
        #expect(commit.hasSuffix("[ \"$s\" = 42 ] && mv -- '/sdcard/.a b.part-1' '/sdcard/a b'"))
        #expect(ADBFileSystem.moveCommand("/sdcard/a b", to: "/sdcard/c") == "mv -- '/sdcard/a b' '/sdcard/c'")
        #expect(ADBFileSystem.moveCommand("/sdcard/a.txt", to: "/sdcard/Other/A.txt") == "mv -- '/sdcard/a.txt' '/sdcard/Other/A.txt'")
        let recase = ADBFileSystem.moveCommand("/sdcard/a.txt", to: "/sdcard/A.txt")
        #expect(recase.hasPrefix("mv -- '/sdcard/a.txt' '/sdcard/.a.txt.rename-") && recase.contains("' '/sdcard/A.txt' || { mv -- '/sdcard/.a.txt.rename-"))
        let df = "Filesystem     1K-blocks     Used Available Use% Mounted on\n/dev/fuse      111381484 52011304  59239108  47% /storage/emulated\n"
        #expect(ADBOutput.space(df) == StorageSpace(used: 52_011_304 * 1024, free: 59_239_108 * 1024))
        #expect(ADBOutput.space("df: /nope: No such file or directory") == nil)
    }
}

/// The share over real HTTP on 127.0.0.1, asked with curl.
@Suite("HTTP server (S-016)")
struct HTTPServerTests {
    let box: Sandbox
    let server: HTTPServer
    var base: String { "http://127.0.0.1:\(server.port)/tok" }

    init() async throws {
        box = try Sandbox()
        let share = WebDAVShare(files: box.device, content: box.device, root: "/sdcard", prefix: "/tok")
        server = try await HTTPServer { try await share.handle($0) }
    }

    /// Returns the status code and the body.
    func curl(_ arguments: [String]) async throws -> (Int, String) {
        let result = try await ProcessRunner().run("/usr/bin/curl", ["-s", "--max-time", "20", "-w", "\n%{http_code}"] + arguments)
        let lines = result.text.components(separatedBy: "\n")
        return (Int(lines.last ?? "") ?? 0, lines.dropLast().joined(separator: "\n"))
    }

    @Test func uploadsDownloadsAndListsOverOneServer() async throws {
        defer { server.stop() }
        let big = String(repeating: "0123456789", count: 300_000)
        let local = box.root.appending(path: "big.txt")
        try Data(big.utf8).write(to: local)
        // Known length, then chunked (how macOS uploads).
        #expect(try await curl(["-T", local.path, "\(base)/Download/big.txt"]).0 == 201)
        #expect(try await curl(["-T", local.path, "-H", "Transfer-Encoding: chunked", "\(base)/Download/big%202.txt"]).0 == 201)
        #expect(box.read(.device, "/sdcard/Download/big.txt") == big)
        #expect(box.read(.device, "/sdcard/Download/big 2.txt") == big)
        let (status, body) = try await curl(["\(base)/Download/big.txt"])
        #expect(status == 200 && body == big)
        #expect(try await curl(["-r", "5-14", "\(base)/Download/big.txt"]) == (206, "5678901234"))
        let listing = try await curl(["-X", "PROPFIND", "-H", "Depth: 1", "\(base)/Download/"])
        #expect(listing.0 == 207 && listing.1.contains("big%202.txt"))
        // Two requests on one connection.
        let two = try await curl(["-X", "PROPFIND", "-H", "Depth: 0", "\(base)/", "\(base)/Download/"])
        #expect(two.0 == 207)
    }

    @Test func refusesOtherHostsAndPaths() async throws {
        defer { server.stop() }
        // A length that makes no sense ends that connection, not the app.
        _ = try await curl(["-X", "PUT", "-H", "Content-Length: -1", "-d", "x", "\(base)/Download/a.txt"])
        _ = try await curl(["-X", "PUT", "-H", "Transfer-Encoding: chunked", "-H", "Content-Length:", "--data-binary", "x", "\(base)/Download/b.txt"])
        #expect(try await curl(["-H", "Host: evil.example", "\(base)/"]).0 == 403)
        #expect(try await curl(["-X", "PROPFIND", "http://127.0.0.1:\(server.port)/"]).0 == 404)
        #expect(try await curl(["-X", "DELETE", "-H", "Host: evil.example", "\(base)/Download"]).0 == 403)
        #expect(try await box.names(.device, "/sdcard") == ["Download"])
    }
}
