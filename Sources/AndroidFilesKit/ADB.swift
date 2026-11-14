import Foundation

/// A device line from `adb devices -l`.
public struct DeviceInfo: Sendable, Hashable, Identifiable {
    public enum State: Sendable, Hashable {
        /// Connected and allowed: files can be read.
        case ready
        /// The tablet has not allowed this Mac yet ("Allow USB debugging?").
        case unauthorized
        case offline
        case other(String)
    }

    public var serial: String
    public var state: State
    /// From the `model:` field, like "OPD2505". The app asks the tablet for a nicer name.
    public var model: String?

    public var id: String { serial }

    public init(serial: String, state: State, model: String?) {
        self.serial = serial
        self.state = state
        self.model = model
    }
}

/// Turns adb's text output into values.
public enum ADBOutput {
    public static func devices(_ text: String) -> [DeviceInfo] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("List of devices") || line.hasPrefix("*") { return nil }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 2 else { return nil }
            let state: DeviceInfo.State = switch fields[1] {
            case "device": .ready
            case "unauthorized": .unauthorized
            case "offline": .offline
            default: .other(fields[1])
            }
            let model = fields.dropFirst(2).first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)) }
            return DeviceInfo(serial: fields[0], state: state, model: model)
        }
    }

    /// Parses the NUL-separated `kind TAB size TAB mtime TAB name` records that
    /// `ADBFileSystem.listCommand` prints. NUL ends each record because a name may
    /// hold tabs or newlines but never NUL. Records whose name holds "/" are the
    /// listed folder itself (toybox find prints it), so they are dropped.
    public static func listing(_ data: Data, folder: String) -> [FileEntry] {
        data.split(separator: 0).compactMap { record in
            let text = String(decoding: record, as: UTF8.self)
            let parts = text.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4, FilePath.isValidName(parts[3]) else { return nil }
            let kind: FileEntry.Kind = switch parts[0] {
            case "d": .folder
            case "f": .file
            default: .other
            }
            return FileEntry(name: parts[3], path: FilePath.join(folder, parts[3]), kind: kind,
                             size: Int64(parts[1]) ?? 0,
                             modified: Date(timeIntervalSince1970: Double(parts[2]) ?? 0))
        }
    }

    /// The first "adb: error:" line (later ones are fallout, like "failed to read copy
    /// response: EOF"), else the last line ("rm: x: Permission denied").
    public static func errorMessage(_ result: CommandResult, fallback: String) -> String {
        let lines = result.stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard var line = lines.first(where: { $0.hasPrefix("adb: error: ") }) ?? lines.last(where: { !$0.isEmpty })
        else { return fallback }
        for prefix in ["adb: error: ", "error: "] where line.hasPrefix(prefix) { line.removeFirst(prefix.count) }
        return line
    }
}

extension ADBOutput {
    /// "inet 192.168.1.203/24 brd ..." from `ip -f inet addr show wlan0` → "192.168.1.203".
    public static func wifiAddress(_ text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let words = line.split(separator: " ")
            if let at = words.firstIndex(of: "inet"), at + 1 < words.count {
                return words[at + 1].split(separator: "/").first.map(String.init)
            }
        }
        return nil
    }

    /// `adb connect` and `adb pair` print their outcome and may exit 0 when they failed.
    /// nil when it worked, else the reason.
    public static func wifiFailure(_ result: CommandResult, success: [String]) -> String? {
        let text = (result.text + "\n" + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        if success.contains(where: { text.localizedCaseInsensitiveContains($0) }) { return nil }
        let line = text.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        return line.isEmpty ? "adb gave no answer" : line
    }
}

/// Quotes one word for the tablet's shell. `adb shell` joins its arguments
/// into one command line, so every path must be quoted.
public func shellQuote(_ word: String) -> String {
    "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// The adb program and the calls the app makes to it.
public struct ADB: Sendable {
    public let path: String
    let runner: CommandRunner
    /// Set when the adb server answers for the tablet on its socket: shell commands and files
    /// then go straight to it (ADBServer.swift). nil: every call runs the `adb` program.
    public var server: ADBServer?

    public init(path: String, runner: CommandRunner = ProcessRunner(), server: ADBServer? = nil) {
        self.path = path
        self.runner = runner
        self.server = server
    }

    /// This adb with the direct connection, when the server answers for `serial` that way.
    /// ANDROIDFILES_ADB=cli keeps to the `adb` program.
    public func direct(for serial: String, environment: [String: String] = ProcessInfo.processInfo.environment) async -> ADB {
        guard environment["ANDROIDFILES_ADB"] != "cli" else { return self }
        let candidate = ADBServer.standard(environment: environment)
        let probe = try? await withTimeout(.seconds(5), "") { try await candidate.shell(serial, "echo direct") }
        guard let probe, probe.status == 0, probe.text.trimmingCharacters(in: .whitespacesAndNewlines) == "direct" else { return self }
        var copy = self
        copy.server = candidate
        return copy
    }

    /// Apps started from Finder get no shell PATH, so look where adb is usually installed.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment,
                              isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        if let custom = environment["ADB_PATH"], !custom.isEmpty { return isExecutable(custom) ? custom : nil }
        let home = environment["HOME"] ?? NSHomeDirectory()
        let candidates = ["/opt/homebrew/bin/adb", "/usr/local/bin/adb",
                          home + "/Library/Android/sdk/platform-tools/adb"]
        return candidates.first(where: isExecutable)
    }

    public func devices() async throws -> [DeviceInfo] {
        let result = try await runner.run(path, ["devices", "-l"])
        guard result.status == 0 else {
            throw FileError(ADBOutput.errorMessage(result, fallback: "adb devices failed"))
        }
        return ADBOutput.devices(result.text)
    }

    public func shell(_ serial: String, _ command: String) async throws -> CommandResult {
        if let server { return try await server.shell(serial, command) }
        return try await runner.run(path, ["-s", serial, "shell", command])
    }

    /// Wi-Fi: the tablet, plugged in, listens on port 5555 until it restarts. Returns "ip:5555".
    public func switchToWiFi(_ serial: String) async throws -> String {
        let shown = try await shell(serial, "ip -f inet addr show wlan0")
        guard let ip = ADBOutput.wifiAddress(shown.text) else {
            throw FileError("The tablet is not on Wi-Fi")
        }
        let result = try await runner.run(path, ["-s", serial, "tcpip", "5555"])
        guard result.status == 0 else { throw FileError(ADBOutput.errorMessage(result, fallback: "adb tcpip failed")) }
        let address = "\(ip):5555"
        // adbd restarts on the tablet: give it a moment.
        for attempt in 0..<5 {
            try await Task.sleep(for: .milliseconds(attempt == 0 ? 1000 : 700))
            if (try? await connect(address)) != nil { return address }
        }
        try await connect(address)
        return address
    }

    /// `adb connect ip:port`. Gives up after 10 s (an address nobody answers would hang for a minute).
    public func connect(_ address: String) async throws {
        let result = try await withTimeout(.seconds(10), "No answer from \(address)") {
            try await runner.run(path, ["connect", address])
        }
        if let failure = ADBOutput.wifiFailure(result, success: ["connected to"]) { throw FileError(failure) }
    }

    /// `adb pair ip:port code`, with the code the tablet shows under Wireless debugging › Pair with code.
    public func pair(_ address: String, code: String) async throws {
        let result = try await withTimeout(.seconds(15), "No answer from \(address)") {
            try await runner.run(path, ["pair", address, code])
        }
        if let failure = ADBOutput.wifiFailure(result, success: ["Successfully paired"]) { throw FileError(failure) }
    }

    /// The tablet stops listening on the network (`adb usb`, until switched again), and adb lets go.
    public func disconnect(_ address: String) async {
        _ = try? await withTimeout(.seconds(5), "") { try await runner.run(path, ["-s", address, "usb"]) }
        _ = try? await runner.run(path, ["disconnect", address])
    }

    /// "OnePlus Pad Go 2" rather than "OPD2505" when the tablet says so.
    public func deviceName(_ serial: String) async -> String? {
        let props = ["ro.vendor.oplus.market.name", "ro.product.marketname", "ro.product.vendor.marketname",
                     "ro.product.brand", "ro.product.model"]
        let command = props.map { "getprop \($0)" }.joined(separator: "; ")
        guard let result = try? await shell(serial, command), result.status == 0 else { return nil }
        let values = result.text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard values.count >= 5 else { return nil }
        if let market = values[0..<3].first(where: { !$0.isEmpty }) { return market }
        let brand = values[3], model = values[4]
        if model.isEmpty { return nil }
        return brand.isEmpty || model.localizedCaseInsensitiveContains(brand) ? model : "\(brand) \(model)"
    }
}

/// The tablet's files over `adb shell`. Their content streams through `FileContent`.
public struct ADBFileSystem: FileSystem {
    public let adb: ADB
    public let serial: String
    public var deletesPermanently: Bool { true }

    public init(adb: ADB, serial: String) {
        self.adb = adb
        self.serial = serial
    }

    /// toybox find (Android 7+) has no %y, so each kind gets its own -printf. -L
    /// lists what a symlink points to, like /sdcard → /storage/emulated/0.
    public static func listCommand(_ folder: String) -> String {
        let dir = shellQuote(folder.hasSuffix("/") ? folder : folder + "/")
        let fields = "\\t%s\\t%T@\\t%f\\0"
        return "find -L \(dir) -mindepth 1 -maxdepth 1 \\( -type d -printf 'd\(fields)' \\)"
            + " -o \\( -type f -printf 'f\(fields)' \\) -o -printf 'o\(fields)'"
    }

    public func list(_ folder: String) async throws -> [FileEntry] {
        let result = try await adb.shell(serial, Self.listCommand(folder))
        // find exits 1 when it can't read some entries but still lists the rest. With
        // nothing listed it is a real failure (toybox may still print the folder itself).
        let entries = ADBOutput.listing(result.stdout, folder: folder)
        if result.status != 0 && entries.isEmpty {
            throw FileError("Can't open “\(FilePath.name(folder))”: "
                + ADBOutput.errorMessage(result, fallback: "the tablet refused"))
        }
        return entries
    }

    public func exists(_ path: String) async throws -> Bool {
        let q = shellQuote(path)
        let result = try await adb.shell(serial, "[ -e \(q) ] || [ -L \(q) ]")
        return result.status == 0
    }

    /// `du -b` counts bytes (not blocks), for a file or a whole folder.
    public func size(_ path: String) async throws -> Int64 {
        let result = try await adb.shell(serial, "du -s -b -- \(shellQuote(path))")
        guard result.status == 0, let first = result.text.split(whereSeparator: { $0 == "\t" || $0 == " " }).first,
              let bytes = Int64(first) else {
            throw FileError(ADBOutput.errorMessage(result, fallback: "Can't measure “\(FilePath.name(path))”"))
        }
        return bytes
    }

    public func makeFolder(_ path: String) async throws {
        try await run("mkdir -- \(shellQuote(path))", "Can't create the folder")
    }

    public func move(_ path: String, to: String) async throws {
        try await run(Self.moveCommand(path, to: to), "Can't move “\(FilePath.name(path))”")
    }

    /// The tablet's storage ignores case, and so ignores a rename that changes only the case
    /// (a.txt → A.txt): that one goes through another name.
    public static func moveCommand(_ path: String, to: String) -> String {
        let plain = "mv -- \(shellQuote(path)) \(shellQuote(to))"
        guard path != to, FilePath.parent(path) == FilePath.parent(to),
              FilePath.name(path).compare(FilePath.name(to), options: .caseInsensitive) == .orderedSame else { return plain }
        let aside = FilePath.join(FilePath.parent(path), ".\(FilePath.name(path)).rename-\(UUID().uuidString.prefix(8))")
        return "mv -- \(shellQuote(path)) \(shellQuote(aside)) && { mv -- \(shellQuote(aside)) \(shellQuote(to)) || { mv -- \(shellQuote(aside)) \(shellQuote(path)); false; }; }"
    }

    public func copy(_ path: String, to: String) async throws {
        try await run("cp -R -- \(shellQuote(path)) \(shellQuote(to))", "Can't copy “\(FilePath.name(path))”")
    }

    public func delete(_ path: String) async throws {
        // A slip in a caller must never become `rm -rf /sdcard`.
        guard path.split(separator: "/").count >= 2 else {
            throw FileError("Refusing to delete “\(path)”: it is a top-level folder")
        }
        try await run("rm -rf -- \(shellQuote(path))", "Can't delete “\(FilePath.name(path))”")
    }

    private func run(_ command: String, _ failure: String) async throws {
        let result = try await adb.shell(serial, command)
        if result.status != 0 {
            throw FileError("\(failure): \(ADBOutput.errorMessage(result, fallback: "exit \(result.status)"))")
        }
    }
}

/// Runs `work`, cancelling it (and the process it runs) after `limit`.
func withTimeout<T: Sendable>(_ limit: Duration, _ message: String,
                              _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await work() }
        group.addTask { try await Task.sleep(for: limit); return nil }
        defer { group.cancelAll() }
        do {
            guard let first = try await group.next(), let value = first else { throw FileError(message) }
            return value
        } catch is CancellationError where !Task.isCancelled {
            throw FileError(message)
        }
    }
}
