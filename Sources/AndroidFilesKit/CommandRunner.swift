import Foundation

public struct CommandResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: Data
    public var stderr: String

    public init(status: Int32, stdout: Data, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var text: String { String(decoding: stdout, as: UTF8.self) }
}

/// Runs a program and waits for it. Tests swap in a fake that returns canned output.
public protocol CommandRunner: Sendable {
    func run(_ executable: String, _ arguments: [String]) async throws -> CommandResult
}

/// Runs a real process. Cancelling the task terminates the process, which is
/// how a long `adb pull` stops when the person presses Cancel.
public struct ProcessRunner: CommandRunner {
    public init() {}

    public func run(_ executable: String, _ arguments: [String]) async throws -> CommandResult {
        let process = Process()
        (process.executableURL, process.arguments) = ExactArguments.launch(executable, arguments)
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let box = ProcessBox(process)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Read both pipes on their own threads: a full pipe would block the child.
                DispatchQueue.global().async {
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: FileError("Can't run \(executable): \(error.localizedDescription)"))
                        return
                    }
                    // Cancelled before the process existed: stop it now.
                    if box.cancelled { process.terminate() }
                    let group = DispatchGroup()
                    let collected = OutputBox()
                    DispatchQueue.global().async(group: group) {
                        collected.stdout = out.fileHandleForReading.readDataToEndOfFile()
                    }
                    DispatchQueue.global().async(group: group) {
                        collected.stderr = err.fileHandleForReading.readDataToEndOfFile()
                    }
                    group.wait()
                    process.waitUntilExit()
                    // Cancelled, and our terminate() ended it (by the signal, or a failing exit
                    // after catching it). A process that had already finished on its own
                    // reports its real result: its work is done.
                    if box.cancelled && (process.terminationReason == .uncaughtSignal || process.terminationStatus != 0) {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(returning: CommandResult(
                            status: process.terminationStatus, stdout: collected.stdout,
                            stderr: String(decoding: collected.stderr, as: UTF8.self)))
                    }
                }
            }
        } onCancel: {
            box.cancel()
        }
    }
}

private final class ProcessBox: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var _cancelled = false

    init(_ process: Process) { self.process = process }

    var cancelled: Bool { lock.withLock { _cancelled } }

    func cancel() {
        lock.withLock { _cancelled = true }
        if process.isRunning { process.terminate() }
    }
}

private final class OutputBox: @unchecked Sendable {
    var stdout = Data()
    var stderr = Data()
}

/// Process rewrites every argument the way file names are stored on a Mac: "ñ" becomes
/// "n" plus a combining tilde. On the tablet those are two different names, so a file named
/// on Android could not be reached, and one sent from here got the Mac's spelling.
/// Arguments with such characters go through /bin/sh as plain ASCII, and arrive byte for byte.
enum ExactArguments {
    static func launch(_ executable: String, _ arguments: [String]) -> (URL, [String]) {
        // An argument ending in a line break would lose it in $(…): left as it is.
        guard arguments.contains(where: { !$0.utf8.allSatisfy { $0 < 0x80 } }),
              !arguments.contains(where: { $0.hasSuffix("\n") }) else {
            return (URL(fileURLWithPath: executable), arguments)
        }
        let words = ([executable] + arguments).map { word in
            word.utf8.allSatisfy { $0 < 0x80 } ? shellQuote(word) : "\"$(printf %b '\(octal(word))')\""
        }
        return (URL(fileURLWithPath: "/bin/sh"), ["-c", "exec " + words.joined(separator: " ")])
    }

    /// Every byte that is not a letter, a digit or one of a few safe signs as \0ooo, for printf %b.
    static func octal(_ word: String) -> String {
        var out = ""
        for byte in word.utf8 {
            let scalar = Unicode.Scalar(byte)
            if byte < 0x80, CharacterSet.alphanumerics.contains(scalar) || " ./_-".unicodeScalars.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else {
                // Always three digits: a digit that follows must not be read as part of the number.
                let digits = String(byte, radix: 8)
                out += "\\0" + String(repeating: "0", count: 3 - digits.count) + digits
            }
        }
        return out
    }
}
