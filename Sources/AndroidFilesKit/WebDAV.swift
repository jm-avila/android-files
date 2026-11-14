import Foundation

/// One WebDAV request, as the share needs it. `target` is the raw request path ("/<prefix>/a%20b").
public struct DAVRequest: Sendable {
    public var method: String
    public var target: String
    /// Header names in lower case.
    public var headers: [String: String]
    /// The next piece of the body, or nil at its end.
    public var body: @Sendable () async throws -> Data?

    public init(method: String, target: String, headers: [String: String] = [:],
                body: @escaping @Sendable () async throws -> Data? = { nil }) {
        self.method = method
        self.target = target
        self.headers = headers
        self.body = body
    }
}

public struct DAVResponse: Sendable {
    public enum Body: Sendable {
        case none
        case data(Data)
        /// `length` bytes, handed to the sink piece by piece.
        case stream(length: Int64, @Sendable (@Sendable (Data) async throws -> Void) async throws -> Void)
    }

    public var status: Int
    public var headers: [String: String]
    public var body: Body

    public init(_ status: Int, headers: [String: String] = [:], body: Body = .none) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// Serves one folder of a `FileSystem` as a WebDAV share, which macOS mounts as a
/// volume: this is how the tablet shows up in Finder.
///
/// Finder's own files (`._name` with a file's extra attributes, `.DS_Store`) stay in
/// memory here and never reach the tablet.
public actor WebDAVShare {
    private let files: FileSystem
    private let content: FileContent
    /// The folder served as the share's top ("/sdcard").
    private let root: String
    /// The first part of every URL ("/<token>"): a secret, so only the mount can ask.
    private let prefix: String
    private var listings: [String: (at: Date, entries: [FileEntry])] = [:]
    private var shadow: [String: Data] = [:]
    private var space: (at: Date, value: StorageSpace?)?
    /// Counts changes, so a listing fetched across one is not kept.
    private var generation = 0
    /// Uploads running now.
    private var uploads = 0
    /// New files Finder has named but not filled yet. Finder creates every file empty, then sends
    /// its content: the empty one waits here, so a file costs the tablet one write, not two.
    /// One that gets no content is written empty after a moment (`settle`).
    private var pending: [String: Date] = [:]
    /// Paths whose content is being written now.
    private var writing: Set<String> = []
    private var settling = false
    /// Empty files being written now. A write to the same name waits for it, or the empty
    /// one could land on top of the content.
    private var materializing: [String: Task<Void, Never>] = [:]

    static let listingLife: TimeInterval = 2
    /// How long an empty new file waits for its content before it is written empty.
    static let pendingLife: TimeInterval = 3
    /// A new file up to this size is created in one step (`FileContent.create`).
    static let smallFile = 256 * 1024
    static let shadowFileLimit = 8 * 1024 * 1024
    static let shadowCountLimit = 4000

    public init(files: FileSystem, content: FileContent, root: String, prefix: String) {
        self.files = files
        self.content = content
        self.root = root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
        self.prefix = prefix
    }

    /// For `HTTPServer`. Made here, outside any actor of the caller's, so requests never wait for the app's main thread.
    public nonisolated var handler: @Sendable (DAVRequest) async throws -> DAVResponse {
        { try await self.handle($0) }
    }

    /// Errors thrown come from reading the request's body: the connection is broken.
    public func handle(_ request: DAVRequest) async throws -> DAVResponse {
        do {
            return try await answer(request)
        } catch is TabletUnreachable {
            return DAVResponse(503)
        }
    }

    private func answer(_ request: DAVRequest) async throws -> DAVResponse {
        guard let asked = resolve(request.target) else { return DAVResponse(404) }
        let path = await onTablet(asked)
        switch request.method {
        case "OPTIONS":
            return DAVResponse(200, headers: ["DAV": "1, 2", "MS-Author-Via": "DAV",
                "Allow": "OPTIONS, GET, HEAD, PUT, DELETE, MKCOL, MOVE, COPY, PROPFIND, PROPPATCH, LOCK, UNLOCK"])
        case "PROPFIND": return try await propfind(path, depth: request.headers["depth"] ?? "1")
        case "GET", "HEAD": return try await get(path, request)
        case "PUT": return try await put(path, request)
        case "DELETE": return try await delete(path)
        case "MKCOL": return try await makeFolder(path)
        case "MOVE", "COPY": return try await transfer(path, request)
        case "LOCK": return try await lock(path, request)
        case "UNLOCK":
            // Locked and let go with nothing written: an empty file was wanted.
            if pending[path] != nil && !writing.contains(path) { await materialize(path) }
            return DAVResponse(204)
        case "PROPPATCH":
            return multistatus("<D:response><D:href>\(href(path, folder: false))</D:href><D:status>HTTP/1.1 200 OK</D:status></D:response>")
        default: return DAVResponse(405)
        }
    }

    // MARK: Paths

    /// A request path or a Destination URL → the path on the tablet. nil when it is outside the share.
    func resolve(_ target: String) -> String? {
        // A request names a path; a Destination header names a whole URL.
        let raw = target.hasPrefix("/") ? String(target.prefix { $0 != "?" })
            : URLComponents(string: target)?.percentEncodedPath ?? ""
        guard raw == prefix || raw.hasPrefix(prefix + "/") else { return nil }
        var path = root == "/" ? "" : root
        for part in raw.dropFirst(prefix.count).split(separator: "/") {
            guard let name = part.removingPercentEncoding, FilePath.isValidName(name) else { return nil }
            path += "/" + name
        }
        return path.isEmpty ? "/" : path
    }

    /// macOS writes "ñ" as n + a combining tilde; Android writes one character. The same name in
    /// another form is that name: an existing item is found whichever way it is written, and a
    /// new one gets the composed form, as if typed on the tablet.
    private func onTablet(_ path: String) async -> String {
        guard path != root, !path.allSatisfy(\.isASCII) else { return path }
        var real = root == "/" ? "" : root
        for part in path.dropFirst(real.count).split(separator: "/").map(String.init) {
            var name = part
            if !part.allSatisfy(\.isASCII) && !Self.isShadow(part) {
                let composed = part.precomposedStringWithCanonicalMapping
                let names = ((try? await listing(real.isEmpty ? "/" : real)) ?? []).map(\.name)
                // Byte for byte: Swift's == already calls the two forms equal.
                func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
                name = names.first { same($0, part) }
                    ?? names.first { same($0.precomposedStringWithCanonicalMapping, composed) } ?? composed
            }
            real += "/" + name
        }
        return real
    }

    private static let hrefAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    func href(_ path: String, folder: Bool) -> String {
        let inside = path == root ? "" : String(path.dropFirst(root == "/" ? 0 : root.count))
        let encoded = inside.split(separator: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: Self.hrefAllowed) ?? String($0) }
            .joined(separator: "/")
        let url = prefix + (encoded.isEmpty ? "" : "/" + encoded)
        return folder ? url + "/" : url
    }

    /// ".name.androidfiles-part-1A2B3C4D": what `FileContent.write` names a file until it is whole.
    static func isPart(_ name: String) -> Bool {
        guard name.hasPrefix("."), let mark = name.range(of: partMark, options: .backwards) else { return false }
        let id = name[mark.upperBound...]
        return id.count == 8 && id.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isUppercase) }
    }

    static func isShadow(_ path: String) -> Bool {
        let name = FilePath.name(path)
        return name.hasPrefix("._") || name == ".DS_Store"
    }

    // MARK: Looking

    private func listing(_ folder: String) async throws -> [FileEntry] {
        if let cached = listings[folder], Date.now.timeIntervalSince(cached.at) < Self.listingLife { return cached.entries }
        let before = generation
        var entries = try await files.list(folder).filter { $0.kind != .other && !Self.isShadow($0.path) }
        // Uploads that never finished (the tablet was unplugged halfway) are not shown, and go
        // once they are a day old, while nothing is being uploaded.
        let parts = entries.filter { Self.isPart($0.name) && !$0.isFolder }
        if !parts.isEmpty {
            entries.removeAll { Self.isPart($0.name) && !$0.isFolder }
            for part in parts where uploads == 0 && Date.now.timeIntervalSince(part.modified) > 86_400 {
                try? await files.delete(part.path)
            }
        }
        // Something changed while the tablet was answering: this answer may be from before it.
        if generation == before { listings[folder] = (.now, entries) }
        return entries
    }

    /// nil: surely absent. Throws `TabletUnreachable` when the tablet gave no answer: "can't tell"
    /// must never pass for "absent", or a file that is there would be created over.
    private func stat(_ path: String) async throws -> FileEntry? {
        if path == root { return FileEntry(name: "", path: root, kind: .folder, size: 0, modified: .now) }
        if Self.isShadow(path) {
            return shadow[path].map { FileEntry(name: FilePath.name(path), path: path, kind: .file, size: Int64($0.count), modified: .now) }
        }
        return try await onDevice(path) ?? pending[path].map { Self.empty(path, $0) }
    }

    /// What the tablet itself has at `path`: a new file still waiting for its content is not there yet.
    private func onDevice(_ path: String) async throws -> FileEntry? {
        let name = FilePath.name(path), parent = FilePath.parent(path)
        let entries: [FileEntry]
        do {
            entries = try await listing(parent)
        } catch {
            // No such folder is an answer too, but only when the tablet still shows its top folder.
            if (try? await files.exists(root)) == true, (try? await files.exists(parent)) == false { return nil }
            throw TabletUnreachable()
        }
        // The tablet's storage ignores case: "report.pdf" is "Report.pdf".
        return entries.first { $0.name == name } ?? entries.first { Self.sameName($0.name, name) }
    }

    private static func sameName(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: .caseInsensitive) == .orderedSame
    }

    private static func empty(_ path: String, _ date: Date) -> FileEntry {
        FileEntry(name: FilePath.name(path), path: path, kind: .file, size: 0, modified: date)
    }

    /// A folder's items, with the new files still waiting for their content.
    private func children(_ folder: String) async throws -> [FileEntry] {
        var entries = try await listing(folder)
        for (path, date) in pending where FilePath.parent(path) == folder {
            if entries.contains(where: { $0.path == path }) { continue }
            entries.append(Self.empty(path, date))
        }
        return entries
    }

    /// The tablet may differ from what is remembered about these paths: ask it again.
    private func changed(_ paths: String...) {
        generation += 1
        for path in paths {
            listings[FilePath.parent(path)] = nil
            listings = listings.filter { !FilePath.isInside($0.key, path) }
        }
    }

    /// This share itself put `entry` there (or, with nil, removed what was at `path`): the
    /// remembered listing is corrected instead of asked for again. Copying many files would
    /// otherwise list the folder once per file.
    private func note(_ path: String, _ entry: FileEntry?) {
        generation += 1
        listings = listings.filter { !FilePath.isInside($0.key, path) }
        let parent = FilePath.parent(path)
        guard var cached = listings[parent] else { return }
        // As `stat` finds it: the tablet's storage ignores case, so "A.txt" replaces "a.txt".
        let name = FilePath.name(path)
        cached.entries.removeAll { Self.sameName($0.name, name) }
        if let entry { cached.entries.append(entry) }
        listings[parent] = cached
    }

    /// Writes the empty file a waiting name stands for, unless the tablet has that name by now.
    private func materialize(_ path: String) async {
        if let running = materializing[path] { return await running.value }
        // Its content is on the way: the empty file must not land on it.
        guard !writing.contains(path) else { return }
        guard let date = pending.removeValue(forKey: path) else { return }
        let task = Task {
            do {
                guard try await files.exists(path) == false else { return changed(path) }
                try await content.create(path, holding: Data())
                note(path, Self.empty(path, date))
            } catch {
                changed(path)
            }
        }
        materializing[path] = task
        await task.value
        materializing[path] = nil
    }

    /// After a moment, writes the waiting names that got no content.
    private func settleLater() {
        guard !settling else { return }
        settling = true
        Task {
            while !pending.isEmpty {
                try? await Task.sleep(for: .seconds(1))
                let due = pending.filter { Date.now.timeIntervalSince($0.value) >= Self.pendingLife && !writing.contains($0.key) }
                for path in due.keys { await materialize(path) }
            }
            settling = false
        }
    }

    /// Waits until no new file is waiting for its content (for tests, and before the share goes).
    public func settle() async {
        for path in pending.keys where !writing.contains(path) { await materialize(path) }
    }

    private func storage() async -> StorageSpace? {
        if let space, Date.now.timeIntervalSince(space.at) < 30 { return space.value }
        let value = await content.space(root)
        space = (.now, value)
        return value
    }

    private func propfind(_ path: String, depth: String) async throws -> DAVResponse {
        guard let entry = try await stat(path) else { return DAVResponse(404) }
        let dates = DAVDates()
        var xml = props(entry, dates, space: path == root ? await storage() : nil)
        if entry.isFolder && depth != "0" {
            guard let children = try? await children(path) else { throw TabletUnreachable() }
            for child in children { xml += props(child, dates, space: nil) }
            let mine = shadow.keys.filter { FilePath.parent($0) == path }
            for key in mine {
                if let found = try await stat(key) { xml += props(found, dates, space: nil) }
            }
        }
        return multistatus(xml)
    }

    private func props(_ entry: FileEntry, _ dates: DAVDates, space: StorageSpace?) -> String {
        var prop = "<D:getlastmodified>\(dates.http(entry.modified))</D:getlastmodified>"
            + "<D:creationdate>\(dates.iso(entry.modified))</D:creationdate>"
        if entry.isFolder {
            prop += "<D:resourcetype><D:collection/></D:resourcetype>"
        } else {
            prop += "<D:resourcetype/><D:getcontentlength>\(entry.size)</D:getcontentlength>"
        }
        if let space {
            prop += "<D:quota-available-bytes>\(space.free)</D:quota-available-bytes><D:quota-used-bytes>\(space.used)</D:quota-used-bytes>"
        }
        return "<D:response><D:href>\(href(entry.path, folder: entry.isFolder))</D:href><D:propstat><D:prop>\(prop)</D:prop>"
            + "<D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"
    }

    private func multistatus(_ inner: String) -> DAVResponse {
        let xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<D:multistatus xmlns:D=\"DAV:\">\(inner)</D:multistatus>"
        return DAVResponse(207, headers: ["Content-Type": "application/xml; charset=utf-8"], body: .data(Data(xml.utf8)))
    }

    // MARK: Reading

    /// "bytes=0-99", "bytes=100-", "bytes=-50" → the first byte and how many. nil: not a range this serves.
    static func range(_ header: String?, size: Int64) -> (start: Int64, length: Int64)? {
        guard size > 0, let header, header.hasPrefix("bytes="), !header.contains(",") else { return nil }
        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty {
            guard let last = Int64(parts[1]), last > 0 else { return nil }
            let length = min(last, size)
            return (size - length, length)
        }
        guard let start = Int64(parts[0]), start < size else { return nil }
        let end = min(Int64(parts[1]) ?? size - 1, size - 1)
        return end >= start ? (start, end - start + 1) : nil
    }

    private func get(_ path: String, _ request: DAVRequest) async throws -> DAVResponse {
        guard let entry = try await stat(path) else { return DAVResponse(404) }
        guard !entry.isFolder else { return DAVResponse(200, headers: ["Content-Length": "0"]) }
        var headers = ["Accept-Ranges": "bytes", "Last-Modified": DAVDates().http(entry.modified),
                       "ETag": "\"\(entry.size)-\(Int(entry.modified.timeIntervalSince1970))\"",
                       "Content-Type": "application/octet-stream"]
        var status = 200
        var start: Int64 = 0
        var length = entry.size
        if let wanted = Self.range(request.headers["range"], size: entry.size) {
            (start, length) = wanted
            status = 206
            headers["Content-Range"] = "bytes \(start)-\(start + length - 1)/\(entry.size)"
        }
        headers["Content-Length"] = String(length)
        if request.method == "HEAD" || length == 0 { return DAVResponse(status, headers: headers) }
        if let data = shadow[path] {
            return DAVResponse(status, headers: headers, body: .data(data.subdata(in: Int(start)..<Int(start + length))))
        }
        let content = content
        return DAVResponse(status, headers: headers, body: .stream(length: length) { [start, length] sink in
            try await content.read(path, from: start, length: length, to: sink)
        })
    }

    // MARK: Changing

    private func put(_ path: String, _ request: DAVRequest) async throws -> DAVResponse {
        guard path != root else { return DAVResponse(405) }
        if Self.isShadow(path) {
            var data = Data()
            while let piece = try await request.body() {
                if data.count <= Self.shadowFileLimit { data.append(piece) }
            }
            guard data.count <= Self.shadowFileLimit else { return DAVResponse(507) }
            if shadow.count >= Self.shadowCountLimit { shadow.removeAll() }
            let existed = shadow.updateValue(data, forKey: path) != nil
            return DAVResponse(existed ? 204 : 201)
        }
        guard FilePath.isAndroidSafe(FilePath.name(path)) else { return DAVResponse(403) }
        // From here on no empty file is written for this name (`materialize`): set before the
        // first wait, or one could start while the content is on its way and land on top of it.
        let first = writing.insert(path).inserted
        defer { if first { writing.remove(path) } }
        await materializing[path]?.value
        let real = try await onDevice(path)
        let waiting = pending[path] != nil
        let existing = real ?? (waiting ? Self.empty(path, .now) : nil)
        if existing?.isFolder == true { return DAVResponse(405) }
        // Asked first: the tablet's file channel would make a missing folder on its way.
        guard try await stat(FilePath.parent(path))?.isFolder == true else { return DAVResponse(409) }
        // New only when the tablet has nothing there: one step would not protect what it replaces.
        let isNew = real == nil
        // The start of the body tells a small file (written in one step) from a stream.
        var start = Data()
        var ended = false
        while start.count <= Self.smallFile {
            guard let piece = try await request.body() else { ended = true; break }
            start.append(piece)
        }
        if ended && start.isEmpty && isNew {
            // Finder's empty new file: its content follows in a moment. Nothing goes to the tablet yet.
            if !waiting {
                pending[path] = .now
                generation += 1
                settleLater()
            }
            return DAVResponse(waiting ? 204 : 201)
        }
        // Body errors (the connection broke) pass through; the tablet's refusals become a status.
        let failure = BodyFailure()
        uploads += 1
        defer { uploads -= 1 }
        var size = Int64(start.count)
        do {
            if ended && isNew {
                try await content.create(path, holding: start)
            } else {
                let head = OnePiece(start)
                let counter = ByteCount()
                let whole = ended
                try await content.write(path) {
                    if let data = head.next() { return data }
                    if whole { return nil }
                    do {
                        let data = try await request.body()
                        counter.add(data?.count ?? 0)
                        return data
                    } catch { failure.error = error; throw error }
                }
                size += counter.total
            }
        } catch {
            changed(path)
            if let broken = failure.error { throw broken }
            // The folder is there and the name is fine: the tablet failed (full, unplugged).
            return DAVResponse(500)
        }
        pending[path] = nil
        note(path, FileEntry(name: FilePath.name(path), path: path, kind: .file, size: size, modified: .now))
        return DAVResponse(existing == nil ? 201 : 204)
    }

    private func delete(_ path: String) async throws -> DAVResponse {
        guard path != root else { return DAVResponse(403) }
        await materializing[path]?.value
        if Self.isShadow(path) { return DAVResponse(shadow.removeValue(forKey: path) == nil ? 404 : 204) }
        guard try await stat(path) != nil else { return DAVResponse(404) }
        // A new file still waiting for its content never reached the tablet.
        if pending.removeValue(forKey: path) != nil {
            generation += 1
            forgetShadow(of: path)
            return DAVResponse(204)
        }
        do { try await files.delete(path) } catch {
            changed(path)
            return DAVResponse(403)
        }
        forgetShadow(of: path)
        pending = pending.filter { !FilePath.isInside($0.key, path) }
        note(path, nil)
        return DAVResponse(204)
    }

    private func makeFolder(_ path: String) async throws -> DAVResponse {
        guard try await stat(path) == nil else { return DAVResponse(405) }
        guard FilePath.isAndroidSafe(FilePath.name(path)), !Self.isShadow(path) else { return DAVResponse(403) }
        guard try await stat(FilePath.parent(path))?.isFolder == true else { return DAVResponse(409) }
        do { try await files.makeFolder(path) } catch {
            changed(path)
            return DAVResponse(403)
        }
        note(path, FileEntry(name: FilePath.name(path), path: path, kind: .folder, size: 0, modified: .now))
        return DAVResponse(201)
    }

    private func transfer(_ path: String, _ request: DAVRequest) async throws -> DAVResponse {
        guard let destination = request.headers["destination"], let wanted = resolve(destination) else { return DAVResponse(400) }
        let to = await onTablet(wanted)
        guard path != root, to != root, to != path, !FilePath.isInside(to, path) else { return DAVResponse(403) }
        let move = request.method == "MOVE"
        // A new file still waiting for its content is written first: there must be something to move.
        await materialize(path)
        guard let source = try await stat(path) else { return DAVResponse(404) }
        // The same item under another spelling (a.txt → A.txt) is a rename, not a replace.
        var target = try await stat(to)
        if target?.path == source.path { target = nil }
        if target != nil && request.headers["overwrite"]?.uppercased() == "F" { return DAVResponse(412) }
        // A waiting name at the destination holds nothing on the tablet: there is nothing to step aside.
        let replacesWaiting = pending.removeValue(forKey: to) != nil
        if replacesWaiting { target = nil }
        if Self.isShadow(path) || Self.isShadow(to) {
            guard Self.isShadow(path), Self.isShadow(to) else { return DAVResponse(403) }
            shadow[to] = shadow[path]
            if move { shadow[path] = nil }
            return DAVResponse(target == nil ? 201 : 204)
        }
        guard FilePath.isAndroidSafe(FilePath.name(to)) else { return DAVResponse(403) }
        guard try await stat(FilePath.parent(to))?.isFolder == true else { return DAVResponse(409) }
        // The source must not sit inside what is replaced.
        if target != nil && FilePath.isInside(path, to) { return DAVResponse(403) }
        // What is replaced steps aside until the new one is in place (apps save by writing a
        // copy and moving it over the file), and comes back if that fails.
        let aside = FilePath.join(FilePath.parent(to), ".\(FilePath.name(to)).old-\(UUID().uuidString.prefix(8))")
        do {
            if target != nil { try await files.move(to, to: aside) }
            do {
                if move { try await files.move(path, to: to) } else { try await files.copy(path, to: to) }
            } catch {
                if target != nil { try? await files.move(aside, to: to) }
                throw error
            }
            if target != nil {
                try? await files.delete(aside)
                forgetShadow(of: to)
            }
        } catch {
            changed(path, to)
            return DAVResponse(403)
        }
        // A file's extra attributes follow it.
        let extra = Self.companion(path)
        if !source.isFolder, let data = shadow[extra] { shadow[Self.companion(to)] = data }
        if move { forgetShadow(of: path) }
        if move { note(path, nil) }
        if source.isFolder {
            changed(to)
        } else {
            note(to, FileEntry(name: FilePath.name(to), path: to, kind: .file, size: source.size, modified: source.modified))
        }
        return DAVResponse(target == nil && !replacesWaiting ? 201 : 204)
    }

    /// Finder locks a file before writing it, and creates it by locking a new name.
    private func lock(_ path: String, _ request: DAVRequest) async throws -> DAVResponse {
        var status = 200
        if try await stat(path) == nil {
            if Self.isShadow(path) {
                shadow[path] = Data()
            } else {
                guard FilePath.isAndroidSafe(FilePath.name(path)) else { return DAVResponse(403) }
                guard try await stat(FilePath.parent(path))?.isFolder == true else { return DAVResponse(409) }
                // The name waits for its content (see `pending`). If none comes, `materialize`
                // asks the tablet itself before it writes: an empty file never lands on one that is there.
                pending[path] = .now
                generation += 1
                settleLater()
            }
            status = 201
        }
        let token = "opaquelocktoken:\(UUID().uuidString.lowercased())"
        let xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<D:prop xmlns:D=\"DAV:\"><D:lockdiscovery><D:activelock>"
            + "<D:locktype><D:write/></D:locktype><D:lockscope><D:exclusive/></D:lockscope><D:depth>0</D:depth>"
            + "<D:timeout>Second-600</D:timeout><D:locktoken><D:href>\(token)</D:href></D:locktoken>"
            + "</D:activelock></D:lockdiscovery></D:prop>"
        return DAVResponse(status, headers: ["Content-Type": "application/xml; charset=utf-8", "Lock-Token": "<\(token)>"],
                           body: .data(Data(xml.utf8)))
    }

    static func companion(_ path: String) -> String {
        FilePath.join(FilePath.parent(path), "._" + FilePath.name(path))
    }

    private func forgetShadow(of path: String) {
        shadow[Self.companion(path)] = nil
        shadow = shadow.filter { !FilePath.isInside($0.key, path) }
    }
}

/// The tablet gave no answer, so nothing is known about the path.
struct TabletUnreachable: Error {}

/// The middle of an unfinished upload's name: ".video.mp4.androidfiles-part-1A2B3C4D".
public let partMark = ".androidfiles-part-"

private final class BodyFailure: @unchecked Sendable {
    var error: Error?
}

private final class ByteCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count: Int64 = 0
    func add(_ more: Int) { lock.withLock { count += Int64(more) } }
    var total: Int64 { lock.withLock { count } }
}

/// Dates the way WebDAV wants them.
struct DAVDates {
    private let httpFormat = DateFormatter()
    private let isoFormat = ISO8601DateFormatter()

    init() {
        httpFormat.locale = Locale(identifier: "en_US_POSIX")
        httpFormat.timeZone = TimeZone(identifier: "GMT")
        httpFormat.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    }

    func http(_ date: Date) -> String { httpFormat.string(from: date) }
    func iso(_ date: Date) -> String { isoFormat.string(from: date) }
}
