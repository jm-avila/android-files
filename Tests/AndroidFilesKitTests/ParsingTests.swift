import Foundation
import Testing
@testable import AndroidFilesKit

@Suite("Paths")
struct PathTests {
    @Test func joinParentName() {
        #expect(FilePath.join("/sdcard", "DCIM") == "/sdcard/DCIM")
        #expect(FilePath.join("/", "sdcard") == "/sdcard")
        #expect(FilePath.parent("/sdcard/DCIM") == "/sdcard")
        #expect(FilePath.parent("/sdcard") == "/")
        #expect(FilePath.parent("/") == "/")
        #expect(FilePath.name("/sdcard/DCIM/") == "DCIM")
        #expect(FilePath.name("/") == "/")
    }

    @Test func insideIsByComponent() {
        #expect(FilePath.isInside("/a/b/c", "/a/b"))
        #expect(FilePath.isInside("/a/b", "/a/b"))
        #expect(!FilePath.isInside("/a/bc", "/a/b"))
    }

    @Test func uniqueNamesNumberBeforeTheExtension() {
        #expect(FilePath.uniqueName("a.jpg", isFolder: false, taken: []) == "a.jpg")
        #expect(FilePath.uniqueName("a.jpg", isFolder: false, taken: ["a.jpg"]) == "a 2.jpg")
        #expect(FilePath.uniqueName("a.jpg", isFolder: false, taken: ["a.jpg", "a 2.jpg"]) == "a 3.jpg")
        #expect(FilePath.uniqueName("my.folder", isFolder: true, taken: ["my.folder"]) == "my.folder 2")
        #expect(FilePath.uniqueName("README", isFolder: false, taken: ["README"]) == "README 2")
        #expect(FilePath.uniqueName(".bashrc", isFolder: false, taken: [".bashrc"]) == ".bashrc 2")
    }

    @Test func validNames() {
        #expect(FilePath.isValidName("ok name.txt"))
        for bad in ["", ".", "..", "a/b"] { #expect(!FilePath.isValidName(bad)) }
    }

    @Test func finderOrderPutsFoldersFirstAndNumbersNaturally() {
        let date = Date()
        let items = [
            FileEntry(name: "file 10", path: "/file 10", kind: .file, size: 0, modified: date),
            FileEntry(name: "zeta", path: "/zeta", kind: .folder, size: 0, modified: date),
            FileEntry(name: "file 2", path: "/file 2", kind: .file, size: 0, modified: date),
        ]
        #expect(items.sorted(by: FileEntry.finderOrder).map(\.name) == ["zeta", "file 2", "file 10"])
    }
}

@Suite("adb output")
struct ADBOutputTests {
    @Test func devicesReadyUnauthorizedAndDaemonNoise() {
        let text = """
        * daemon not running; starting now at tcp:5037
        * daemon started successfully
        List of devices attached
        A1B2C3D4E5F6G7H8       device usb:34603008X product:OPD2505EEA model:OPD2505 device:OP6575L1 transport_id:5
        R58M123456\tunauthorized usb:1-1 transport_id:6
        emulator-5554 offline

        """
        let devices = ADBOutput.devices(text)
        #expect(devices.map(\.serial) == ["A1B2C3D4E5F6G7H8", "R58M123456", "emulator-5554"])
        #expect(devices.map(\.state) == [.ready, .unauthorized, .offline])
        #expect(devices[0].model == "OPD2505")
        #expect(devices[1].model == nil)
    }

    @Test func noDevices() {
        #expect(ADBOutput.devices("List of devices attached\n\n").isEmpty)
    }

    @Test func listingKeepsOddNamesAndDropsTheFolderItself() {
        var data = Data()
        for record in ["o\t8192\t1791313172.41\t/sdcard/",
                       "d\t3440\t1735707673.139000000\tDCIM",
                       "f\t12345\t1700000000.5\tmy\tphoto\nwith newline.jpg",
                       "o\t0\t1700000000\tbroken link"] {
            data.append(Data(record.utf8))
            data.append(0)
        }
        let entries = ADBOutput.listing(data, folder: "/sdcard")
        #expect(entries.map(\.name) == ["DCIM", "my\tphoto\nwith newline.jpg", "broken link"])
        #expect(entries.map(\.kind) == [.folder, .file, .other])
        #expect(entries[1].size == 12345)
        #expect(entries[1].path == "/sdcard/my\tphoto\nwith newline.jpg")
        #expect(entries[1].modified == Date(timeIntervalSince1970: 1700000000.5))
    }

    @Test func errorMessageIsTheLastLineWithoutThePrefix() {
        let result = CommandResult(status: 1, stdout: Data(), stderr: "adb: error: failed to stat remote object 'x': No such file or directory\n")
        #expect(ADBOutput.errorMessage(result, fallback: "f") == "failed to stat remote object 'x': No such file or directory")
        #expect(ADBOutput.errorMessage(CommandResult(status: 1, stdout: Data(), stderr: ""), fallback: "f") == "f")
        // Real adb push output: the reason is the first error; "EOF" is fallout.
        let push = CommandResult(status: 1, stdout: Data(), stderr: """
            adb: error: failed to copy '/tmp/a' to '/sdcard/a': remote couldn't create file: Operation not permitted
            /tmp/A/: 4 files pushed, 0 skipped.
            adb: error: failed to read copy response: EOF
            """)
        #expect(ADBOutput.errorMessage(push, fallback: "f").hasSuffix("Operation not permitted"))
    }

    @Test(arguments: ["plain", "it's", "a b", "$(rm -rf /)", "`id`", "semi;colon", "back\\slash", "'", "new\nline"])
    func shellQuoteSurvivesTheShell(_ word: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf %s \(shellQuote(word))"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(String(decoding: out, as: UTF8.self) == word)
    }

    @Test func listCommandQuotesTheFolder() {
        let command = ADBFileSystem.listCommand("/sdcard/it's")
        #expect(command.hasPrefix("find -L '/sdcard/it'\\''s/' -mindepth 1 -maxdepth 1"))
        #expect(command.contains("-type d -printf 'd\\t%s\\t%T@\\t%f\\0'"))
    }
}

/// Answers each command from a table, and records what was run.
final class FakeRunner: CommandRunner, @unchecked Sendable {
    var answers: [(match: String, result: CommandResult)] = []
    private(set) var calls: [[String]] = []
    private let lock = NSLock()

    func answer(_ match: String, status: Int32 = 0, stdout: String = "", stderr: String = "") {
        answers.append((match, CommandResult(status: status, stdout: Data(stdout.utf8), stderr: stderr)))
    }

    func run(_ executable: String, _ arguments: [String]) async throws -> CommandResult {
        lock.withLock { calls.append(arguments) }
        let line = arguments.joined(separator: " ")
        return answers.first { line.contains($0.match) }?.result ?? CommandResult(status: 0, stdout: Data(), stderr: "")
    }
}

@Suite("adb client")
struct ADBClientTests {
    @Test func locatePrefersADB_PATHThenHomebrew() {
        #expect(ADB.locate(environment: ["ADB_PATH": "/x/adb"], isExecutable: { $0 == "/x/adb" }) == "/x/adb")
        #expect(ADB.locate(environment: ["ADB_PATH": "/x/adb"], isExecutable: { _ in false }) == nil)
        #expect(ADB.locate(environment: ["HOME": "/Users/me"], isExecutable: { $0 == "/opt/homebrew/bin/adb" }) == "/opt/homebrew/bin/adb")
        #expect(ADB.locate(environment: ["HOME": "/Users/me"],
                           isExecutable: { $0 == "/Users/me/Library/Android/sdk/platform-tools/adb" })
                == "/Users/me/Library/Android/sdk/platform-tools/adb")
        #expect(ADB.locate(environment: ["HOME": "/Users/me"], isExecutable: { _ in false }) == nil)
    }

    @Test func deviceNamePrefersTheMarketName() async {
        let runner = FakeRunner()
        runner.answer("getprop", stdout: "OnePlus Pad Go 2\n\n\nOnePlus\nOPD2505\n")
        #expect(await ADB(path: "adb", runner: runner).deviceName("S") == "OnePlus Pad Go 2")
        let plain = FakeRunner()
        plain.answer("getprop", stdout: "\n\n\nsamsung\nSM-X200\n")
        #expect(await ADB(path: "adb", runner: plain).deviceName("S") == "samsung SM-X200")
    }

    @Test func listFailsOnlyWhenNothingCameBack() async throws {
        let runner = FakeRunner()
        runner.answer("/data/", status: 1, stderr: "find: /data/: Permission denied\n")
        runner.answer("/sdcard/", status: 1, stdout: "d\t1\t1\tDCIM\0", stderr: "find: x: Permission denied\n")
        let fs = ADBFileSystem(adb: ADB(path: "adb", runner: runner), serial: "S")
        await #expect(throws: FileError("Can't open “data”: find: /data/: Permission denied")) {
            try await fs.list("/data")
        }
        #expect(try await fs.list("/sdcard").map(\.name) == ["DCIM"])
        #expect(runner.calls.first?.prefix(3) == ["-s", "S", "shell"])
    }

    @Test func deleteRefusesTopLevelFolders() async throws {
        let runner = FakeRunner()
        let fs = ADBFileSystem(adb: ADB(path: "adb", runner: runner), serial: "S")
        for path in ["/", "/sdcard", "/sdcard/", ""] {
            await #expect(throws: FileError.self) { try await fs.delete(path) }
        }
        #expect(runner.calls.isEmpty)
        try await fs.delete("/sdcard/Download/a b")
        #expect(runner.calls.last == ["-s", "S", "shell", "rm -rf -- '/sdcard/Download/a b'"])
    }

    @Test func sizeReadsDuBytes() async throws {
        let runner = FakeRunner()
        runner.answer("du -s -b -- '/sdcard/Movies'", stdout: "5377621054\t/sdcard/Movies\n")
        runner.answer("du -s -b -- '/sdcard/gone'", status: 1, stderr: "du: /sdcard/gone: No such file or directory\n")
        let fs = ADBFileSystem(adb: ADB(path: "adb", runner: runner), serial: "S")
        #expect(try await fs.size("/sdcard/Movies") == 5_377_621_054)
        await #expect(throws: FileError("du: /sdcard/gone: No such file or directory")) { try await fs.size("/sdcard/gone") }
    }

    @Test("S-015 Wi-Fi: switch the plugged-in tablet over, and read what connect and pair answer")
    func wifi() async throws {
        let runner = FakeRunner()
        runner.answer("ip -f inet addr show wlan0", stdout: """
            40: wlan0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500
                inet 192.168.1.203/24 brd 192.168.1.255 scope global dynamic wlan0
            """)
        runner.answer("tcpip", stdout: "restarting in TCP mode port: 5555\n")
        runner.answer("connect 192.168.1.203:5555", stdout: "connected to 192.168.1.203:5555\n")
        runner.answer("connect 10.0.0.9:5555", stdout: "failed to connect to '10.0.0.9:5555': Connection refused\n")
        runner.answer("pair", stdout: "Failed: Wrong password or connection was dropped.\n")
        let adb = ADB(path: "adb", runner: runner)
        #expect(try await adb.switchToWiFi("S") == "192.168.1.203:5555")
        #expect(runner.calls.contains(["-s", "S", "tcpip", "5555"]))
        // adb connect exits 0 when it failed: the words tell.
        await #expect(throws: FileError("failed to connect to '10.0.0.9:5555': Connection refused")) {
            try await adb.connect("10.0.0.9:5555")
        }
        await #expect(throws: FileError("Failed: Wrong password or connection was dropped.")) {
            try await adb.pair("192.168.1.203:37000", code: "123456")
        }
        let offline = FakeRunner()
        offline.answer("ip -f inet", stdout: "")
        await #expect(throws: FileError("The tablet is not on Wi-Fi")) { try await ADB(path: "adb", runner: offline).switchToWiFi("S") }
        #expect(!offline.calls.contains { $0.contains("tcpip") })
    }

    @Test func aStuckCommandTimesOut() async throws {
        let start = Date()
        await #expect(throws: FileError("No answer")) {
            try await withTimeout(.milliseconds(300), "No answer") { try await ProcessRunner().run("/bin/sleep", ["5"]) }
        }
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(try await withTimeout(.seconds(5), "No answer") { 42 } == 42)
    }
}

@Suite("process runner")
struct ProcessRunnerTests {
    @Test func returnsOutputAndStatus() async throws {
        let result = try await ProcessRunner().run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"])
        #expect(result.text == "out\n")
        #expect(result.stderr == "err\n")
        #expect(result.status == 3)
    }

    @Test func largeOutputDoesNotBlock() async throws {
        let result = try await ProcessRunner().run("/bin/sh", ["-c", "head -c 3000000 /dev/zero; head -c 200000 /dev/zero >&2"])
        #expect(result.stdout.count == 3_000_000)
        #expect(result.stderr.count == 200_000)
    }

    @Test func cancelStopsTheProcess() async throws {
        let started = Date()
        let task = Task { try await ProcessRunner().run("/bin/sleep", ["10"]) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test func cancelAfterAnErrorExitStillCountsAsCancel() async throws {
        // A program that catches SIGTERM and exits 1 (adb does its own cleanup) is still a cancel.
        let task = Task { try await ProcessRunner().run("/bin/sh", ["-c", "trap 'exit 1' TERM; sleep 10 & wait"]) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func missingProgramIsAnError() async {
        await #expect(throws: FileError.self) { try await ProcessRunner().run("/nope/adb", []) }
    }
}
