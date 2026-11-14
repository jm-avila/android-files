import Foundation
import Network

/// A small HTTP/1.1 server on 127.0.0.1 only, for the WebDAV share. It answers
/// requests whose Host is this machine and port (a web page that points a name at
/// 127.0.0.1 is refused), and hands the rest to `handler`.
public final class HTTPServer: Sendable {
    public typealias Handler = @Sendable (DAVRequest) async throws -> DAVResponse

    public let port: UInt16
    private let listener: NWListener

    /// Starts listening on a free port. `name` is one more host name the mount may use for this
    /// machine ("oneplus-pad.localhost", which every Mac resolves to itself).
    public init(name: String? = nil, handler: @escaping Handler) async throws {
        let hosts = ["127.0.0.1", "localhost"] + (name.map { [$0.lowercased()] } ?? [])
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let queue = DispatchQueue(label: "HTTPServer")
        let started = Once()
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if started.first() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if started.first() { continuation.resume(throwing: FileError("Can't share the tablet: \(error.localizedDescription)")) }
                default: break
                }
            }
            listener.newConnectionHandler = { connection in
                connection.start(queue: queue)
                let port = listener.port?.rawValue ?? 0
                Task { await HTTPConnection(connection).serve(hosts: hosts.map { "\($0):\(port)" }, handler: handler) }
            }
            listener.start(queue: queue)
        }
        self.port = port
    }

    public func stop() { listener.cancel() }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func first() -> Bool { lock.withLock { defer { done = true }; return !done } }
}

struct HTTPError: Error {}

/// One client connection: requests come one after another on it.
actor HTTPConnection {
    private let connection: NWConnection
    private var buffer = Data()

    init(_ connection: NWConnection) { self.connection = connection }

    func serve(hosts: [String], handler: HTTPServer.Handler) async {
        defer { connection.cancel() }
        do {
            while let head = try await head() {
                guard let (method, target, headers) = Self.parse(head) else { return }
                let body = HTTPBody(self, headers: headers)
                guard let host = headers["host"], hosts.contains(host.lowercased()) else {
                    try await body.drain()
                    try await send(Self.head(403, ["Content-Length": "0"]))
                    continue
                }
                let response = try await handler(DAVRequest(method: method, target: target, headers: headers) { try await body.next() })
                try await body.drain()
                if Self.logs {
                    let extra = ["range", "destination", "depth"].compactMap { name in headers[name].map { "\(name)=\($0)" } }
                    FileHandle.standardError.write(Data("http \(method) \(target) \(extra.joined(separator: " ")) -> \(response.status)\n".utf8))
                }
                var fields = response.headers
                switch response.body {
                case .none:
                    if fields["Content-Length"] == nil { fields["Content-Length"] = "0" }
                    try await send(Self.head(response.status, fields))
                case .data(let data):
                    fields["Content-Length"] = String(data.count)
                    try await send(Self.head(response.status, fields) + data)
                case .stream(let length, let produce):
                    fields["Content-Length"] = String(length)
                    try await send(Self.head(response.status, fields))
                    let sent = Counter()
                    try await produce { data in
                        sent.add(data.count)
                        try await self.send(data)
                    }
                    // Fewer bytes than promised: the client must not take the next answer for the rest.
                    guard Int64(sent.value) == length else { return }
                }
                if headers["connection"]?.lowercased() == "close" { return }
            }
        } catch {}
    }

    /// ANDROIDFILES_HTTP_LOG=1 prints each request and its status, to see what Finder asks.
    static let logs = ProcessInfo.processInfo.environment["ANDROIDFILES_HTTP_LOG"] == "1"

    static func parse(_ head: String) -> (String, String, [String: String])? {
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return (String(first[0]), String(first[1]), headers)
    }

    static func head(_ status: Int, _ fields: [String: String]) -> Data {
        let reasons = [200: "OK", 201: "Created", 204: "No Content", 206: "Partial Content", 207: "Multi-Status",
                       400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
                       409: "Conflict", 412: "Precondition Failed", 500: "Internal Server Error", 503: "Service Unavailable", 507: "Insufficient Storage"]
        var text = "HTTP/1.1 \(status) \(reasons[status] ?? "Status")\r\n"
        for (name, value) in fields { text += "\(name): \(value)\r\n" }
        return Data((text + "\r\n").utf8)
    }

    /// The next request's first line and headers. nil when the client closed the connection.
    private func head() async throws -> String? {
        let end = Data("\r\n\r\n".utf8)
        while true {
            if let found = buffer.range(of: end) {
                let head = String(decoding: buffer[buffer.startIndex..<found.lowerBound], as: UTF8.self)
                buffer = Data(buffer[found.upperBound...])
                return head
            }
            guard buffer.count < 64 * 1024 else { throw HTTPError() }
            guard try await fill() else { return nil }
        }
    }

    /// Up to `max` bytes of what the client sent next.
    func take(_ max: Int) async throws -> Data {
        while buffer.isEmpty {
            guard try await fill() else { throw HTTPError() }
        }
        let piece = Data(buffer.prefix(max))
        buffer = Data(buffer.dropFirst(piece.count))
        return piece
    }

    func line() async throws -> String {
        let end = Data("\r\n".utf8)
        while true {
            if let found = buffer.range(of: end) {
                let line = String(decoding: buffer[buffer.startIndex..<found.lowerBound], as: UTF8.self)
                buffer = Data(buffer[found.upperBound...])
                return line
            }
            guard buffer.count < 8 * 1024, try await fill() else { throw HTTPError() }
        }
    }

    private func fill() async throws -> Bool {
        let connection = connection
        let data: Data? = try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: isComplete ? nil : Data())
                }
            }
        }
        guard let data else { return false }
        buffer.append(data)
        return true
    }

    func send(_ data: Data) async throws {
        let connection = connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    func add(_ n: Int) { lock.withLock { total += n } }
    var value: Int { lock.withLock { total } }
}

/// A request's body: a known length, or chunked (how macOS uploads files).
actor HTTPBody {
    private let connection: HTTPConnection
    private var left: Int
    private let chunked: Bool
    private var ended: Bool
    private var mustContinue: Bool

    init(_ connection: HTTPConnection, headers: [String: String]) {
        self.connection = connection
        chunked = headers["transfer-encoding"]?.lowercased().contains("chunked") == true
        left = chunked ? 0 : max(0, Int(headers["content-length"] ?? "") ?? 0)
        ended = !chunked && headers["content-length"].flatMap { Int($0) } ?? 0 <= 0
        mustContinue = headers["expect"]?.lowercased() == "100-continue"
    }

    func next() async throws -> Data? {
        if ended { return nil }
        if mustContinue {
            mustContinue = false
            try await connection.send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
        }
        if chunked && left == 0 {
            let size = try await connection.line()
            guard let count = Int(size.prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces), radix: 16), count >= 0 else { throw HTTPError() }
            if count == 0 {
                // Trailers, then the empty line.
                while try await !connection.line().isEmpty {}
                ended = true
                return nil
            }
            left = count
        }
        let data = try await connection.take(min(left, 256 * 1024))
        left -= data.count
        if left == 0 {
            if chunked { _ = try await connection.line() } else { ended = true }
        }
        return data
    }

    func drain() async throws {
        while try await next() != nil {}
    }
}
