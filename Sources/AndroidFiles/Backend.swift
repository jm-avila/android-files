import Foundation
import AndroidFilesKit

/// What the menu says about the tablet.
enum DeviceStatus: Equatable {
    case searching
    /// adb is not installed where the app looks.
    case noADB
    case noDevice
    /// The tablet has not tapped Allow on "Allow USB debugging?".
    case unauthorized
    case offline
    case failed(String)
    case ready(serial: String, name: String)

    var serial: String? {
        if case let .ready(serial, _) = self { serial } else { nil }
    }
}

/// The tablet in use: its serial and the name it gave.
typealias KnownDevice = (serial: String, name: String)

/// One look at what is plugged in.
struct DeviceScan {
    var status: DeviceStatus
    /// Set with `.ready`: the tablet's storage.
    var storage: DeviceStorage?
    /// Every device adb lists, for the picker when more than one is plugged in.
    var devices: [DeviceInfo] = []
}

/// A tablet's files and their content, as the Finder volume serves them.
typealias DeviceStorage = FileSystem & FileContent

/// Finds the tablet. The app uses adb; test runs use a /tmp folder.
protocol DeviceBackend: Sendable {
    /// `preferred` keeps the chosen device when several are plugged in. `known` is the tablet in
    /// use now: found again, it is not asked for its name a second time.
    func scan(preferred: String?, known: KnownDevice?) async -> DeviceScan
    /// Wi-Fi (see ADB). Each returns or throws a reason to show.
    func switchToWiFi(serial: String) async throws -> String
    func connect(_ address: String) async throws
    func pair(_ address: String, code: String) async throws
    func disconnect(_ address: String) async
}

struct ADBBackend: DeviceBackend {
    private func adb() throws -> ADB {
        guard let path = ADB.locate() else { throw FileError("adb is not installed") }
        return ADB(path: path)
    }

    func switchToWiFi(serial: String) async throws -> String { try await adb().switchToWiFi(serial) }
    func connect(_ address: String) async throws { try await adb().connect(address) }
    func pair(_ address: String, code: String) async throws { try await adb().pair(address, code: code) }
    func disconnect(_ address: String) async { await (try? adb())?.disconnect(address) }

    func scan(preferred: String?, known: KnownDevice?) async -> DeviceScan {
        guard let path = ADB.locate() else { return DeviceScan(status: .noADB) }
        let adb = ADB(path: path)
        let devices: [DeviceInfo]
        do {
            devices = try await adb.devices()
        } catch {
            return DeviceScan(status: .failed(error.localizedDescription))
        }
        let ready = devices.filter { $0.state == .ready }
        guard let device = ready.first(where: { $0.serial == preferred }) ?? ready.first else {
            let status: DeviceStatus = devices.contains { $0.state == .unauthorized } ? .unauthorized
                : devices.isEmpty ? .noDevice : .offline
            return DeviceScan(status: status, devices: devices)
        }
        // The same tablet as before: the app keeps the name and the storage it has.
        if let known, known.serial == device.serial {
            return DeviceScan(status: .ready(serial: device.serial, name: known.name),
                              storage: ADBFileSystem(adb: adb, serial: device.serial), devices: devices)
        }
        // A new one: ask its name, and whether adb's server takes it directly (the fast way).
        let link = await adb.direct(for: device.serial)
        let name = await link.deviceName(device.serial) ?? device.model ?? device.serial
        return DeviceScan(status: .ready(serial: device.serial, name: name),
                          storage: ADBFileSystem(adb: link, serial: device.serial), devices: devices)
    }
}

/// A pretend tablet in `<store>/device`, in the state APP_DEVICE_STATE names
/// (ready, none, unauthorized, offline, noadb). Used only with APP_STORE in /tmp.
struct FolderBackend: DeviceBackend {
    let root: String
    var state: String

    func scan(preferred: String?, known: KnownDevice?) async -> DeviceScan {
        let status: DeviceStatus = switch state {
        case "none": .noDevice
        case "unauthorized": .unauthorized
        case "offline": .offline
        case "noadb": .noADB
        default: .ready(serial: "TEST0001", name: "OnePlus Pad Go 2")
        }
        guard case .ready = status else { return DeviceScan(status: status) }
        return DeviceScan(status: status, storage: LocalFileSystem(root: root, useTrash: false),
                          devices: [DeviceInfo(serial: "TEST0001", state: .ready, model: "OPD2505")])
    }

    // Wi-Fi works on paper only: the pretend tablet stays where it is.
    func switchToWiFi(serial: String) async throws -> String { "192.168.1.50:5555" }
    func connect(_ address: String) async throws {
        guard address.contains(":") else { throw FileError("failed to connect to '\(address)'") }
    }
    func pair(_ address: String, code: String) async throws {
        guard code.count == 6 else { throw FileError("Failed: Wrong password or connection was dropped.") }
    }
    func disconnect(_ address: String) async {}
}

/// Test runs keep everything in the APP_STORE folder in /tmp.
enum TestMode {
    static var store: String? {
        let path = ProcessInfo.processInfo.environment["APP_STORE"] ?? ""
        return path.isEmpty ? nil : path
    }

    /// True for a test run. Refused runs check `isSafe` instead.
    static var isOn: Bool { store != nil }

    /// Test runs must point at /tmp, never at someone's files.
    static var isSafe: Bool {
        guard let store else { return false }
        let resolved = URL(fileURLWithPath: store).resolvingSymlinksInPath().path
        return resolved.hasPrefix("/tmp/") || resolved.hasPrefix("/private/tmp/")
    }
}
