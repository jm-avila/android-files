import AppKit
import Foundation
import AndroidFilesKit

/// The app's state: the tablet, its volume in Finder, and Wi-Fi.
@Observable
final class AppModel {
    static let shared = AppModel.make()

    let backend: DeviceBackend
    private(set) var status: DeviceStatus = .searching
    private(set) var devices: [DeviceInfo] = []
    /// The connected tablet's storage, served to Finder.
    private var storage: DeviceStorage?
    /// Settings reopens on the last tab. Test runs leave it alone.
    var settingsTab: SettingsTab = SettingsTab(rawValue: UserDefaults.standard.string(forKey: "settings.tab") ?? "") ?? .general {
        didSet { if !TestMode.isOn { UserDefaults.standard.set(settingsTab.rawValue, forKey: "settings.tab") } }
    }
    /// The folder Finder shows as the disk. Shared storage, the folder people know.
    static let deviceHome = "/sdcard"
    /// The Wi-Fi address last connected ("192.168.1.203:5555"), tried again while no tablet is ready.
    var wifiAddress: String? = TestMode.isOn ? nil : UserDefaults.standard.string(forKey: "wifi.address") {
        didSet { if !TestMode.isOn { UserDefaults.standard.set(wifiAddress, forKey: "wifi.address") } }
    }
    /// The tablet shows as a volume in Finder while it is connected (FinderVolume.swift).
    /// Test runs turn it on with APP_FINDER=1.
    var showInFinder: Bool = TestMode.isOn ? ProcessInfo.processInfo.environment["APP_FINDER"] == "1"
        : UserDefaults.standard.object(forKey: "showInFinder") as? Bool ?? true {
        didSet {
            if !TestMode.isOn { UserDefaults.standard.set(showInFinder, forKey: "showInFinder") }
            if showInFinder != oldValue { syncFinder(again: true) }
        }
    }
    /// The volume's folder while Finder shows the tablet, and why it could not.
    private(set) var finderPath: String?
    private(set) var finderError: String?
    @ObservationIgnored private let finder = FinderVolume()
    /// The tablet the volume was last mounted for. It stays set after an eject in Finder,
    /// so the volume does not come back by itself.
    @ObservationIgnored private var finderSerial: String?
    @ObservationIgnored private var finderWork: Task<Void, Never>?
    /// A Wi-Fi step running now, and the last one's outcome, for Settings.
    private(set) var wifiBusy = false
    var wifiMessage: String?
    @ObservationIgnored private var lastReconnect = Date.distantPast
    private var preferredSerial: String?
    private var monitor: Task<Void, Never>?

    init(backend: DeviceBackend) {
        self.backend = backend
    }

    /// The real app, or a test run on the APP_STORE folder.
    static func make() -> AppModel {
        if TestMode.isOn && !TestMode.isSafe {
            // A test run pointed at real files: stop before anything is listed or changed.
            print("refused: APP_STORE must be a folder in /tmp")
            exit(1)
        }
        if let store = TestMode.store, TestMode.isSafe {
            let state = ProcessInfo.processInfo.environment["APP_DEVICE_STATE"] ?? "ready"
            return AppModel(backend: FolderBackend(root: store + "/device", state: state))
        }
        return AppModel(backend: ADBBackend())
    }

    var isDeviceReady: Bool { status.serial != nil }

    var deviceName: String {
        if case let .ready(_, name) = status { name } else { "Tablet" }
    }

    /// The first line of the menu: the tablet and what it is doing.
    var statusLine: String {
        switch status {
        case .ready: finderPath != nil ? "\(deviceName): in Finder" : "\(deviceName): connected"
        case .searching: "Looking for a tablet…"
        case .noADB: "adb isn't installed"
        case .noDevice: "No tablet connected"
        case .unauthorized: "Tap Allow on the tablet"
        case .offline: "The tablet is not responding"
        case .failed: "Can't reach adb"
        }
    }

    /// The menu bar icon: a tablet, with a mark when something needs the person.
    var menuSymbol: String {
        switch status {
        case .ready, .searching, .noDevice: finderError == nil ? "ipad.landscape" : "ipad.landscape.badge.exclamationmark"
        case .noADB, .unauthorized, .offline, .failed: "ipad.landscape.badge.exclamationmark"
        }
    }

    // MARK: Device

    /// Looks for the tablet now and every 2 s after.
    func startMonitoring() {
        guard monitor == nil else { return }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.volumeUnmounted() }
        }
        monitor = Task {
            // A volume left by a crash would make Finder wait for an app that is gone.
            let volumes = FinderVolume.folder
            await Task.detached { FinderVolume.unmountAll(in: volumes) }.value
            while !Task.isCancelled {
                await scan()
                reconnectWiFi()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func scan() async {
        let known: KnownDevice? = if case let .ready(serial, name) = status { (serial, name) } else { nil }
        let result = await backend.scan(preferred: preferredSerial ?? status.serial, known: known)
        devices = result.devices
        guard result.status != status else { return }
        let wasSerial = status.serial
        status = result.status
        guard result.status.serial != wasSerial else { return }
        storage = result.status.serial == nil ? nil : result.storage
        syncFinder()
    }

    // MARK: Finder

    /// Mounts or unmounts the volume to match the setting and the tablet. One change at a time.
    /// `again` mounts even when this tablet's volume was ejected in Finder.
    @discardableResult
    func syncFinder(again: Bool = false) -> Task<Void, Never> {
        let work = Task { [previous = finderWork] in
            await previous?.value
            if again && finderPath == nil { finderSerial = nil }
            let wanted = showInFinder ? status.serial : nil
            guard wanted != finderSerial else { return }
            await finder.unmount()
            finderPath = nil
            finderError = nil
            finderSerial = wanted
            guard wanted != nil, let storage else { return }
            do {
                finderPath = try await finder.mount(files: storage, content: storage, root: Self.deviceHome, name: deviceName)
            } catch {
                finderError = error.localizedDescription
            }
        }
        finderWork = work
        return work
    }

    /// "Open in Finder": turns the setting on, mounts, and opens the volume's window.
    func revealInFinder() async {
        showInFinder = true
        await syncFinder(again: true).value
        if let finderPath, !TestMode.isOn { NSWorkspace.shared.open(URL(fileURLWithPath: finderPath)) }
    }

    /// The menu's Eject, the same as ejecting in Finder: the volume goes until the tablet is
    /// connected again or "Open in Finder" is chosen. The setting stays on.
    @discardableResult
    func eject() -> Task<Void, Never> {
        let work = Task { [previous = finderWork] in
            await previous?.value
            await finder.unmount()
            finderPath = nil
        }
        finderWork = work
        return work
    }

    /// Ejected in Finder: stop serving it. It returns with the next connection or "Open in Finder".
    private func volumeUnmounted() {
        guard let finderPath, !FinderVolume.isMounted(finderPath) else { return }
        finder.closed()
        self.finderPath = nil
    }

    // MARK: Wi-Fi

    var isOnWiFi: Bool { status.serial != nil && status.serial == wifiAddress }

    /// The plugged-in tablet starts listening on Wi-Fi, and the app moves to it: the cable can go.
    /// The volume in Finder is mounted again for the new connection.
    func switchToWiFi() async {
        guard let serial = status.serial, !isOnWiFi else { return }
        await wifiStep("You can unplug the tablet.") {
            let address = try await self.backend.switchToWiFi(serial: serial)
            self.useWiFi(address)
        }
    }

    func connect(_ address: String) async {
        let address = address.trimmingCharacters(in: .whitespaces)
        await wifiStep("Connected to \(address).") {
            try await self.backend.connect(address)
            self.useWiFi(address)
        }
    }

    /// Wireless debugging (Android 11+): pair once with the code the tablet shows, then connect.
    func pair(_ address: String, code: String) async {
        let address = address.trimmingCharacters(in: .whitespaces)
        await wifiStep("Paired. Now connect to the address under Wireless debugging (not the pairing one).") {
            try await self.backend.pair(address, code: code.trimmingCharacters(in: .whitespaces))
        }
    }

    /// Back to the cable: forget the address and stop using it.
    func forgetWiFi() async {
        guard let address = wifiAddress else { return }
        await wifiStep("Wi-Fi is off: the tablet listens on the cable only.") {
            self.wifiAddress = nil
            if self.preferredSerial == address { self.preferredSerial = nil }
            await self.backend.disconnect(address)
        }
    }

    private func useWiFi(_ address: String) {
        wifiAddress = address
        preferredSerial = address
    }

    private func wifiStep(_ success: String, _ work: () async throws -> Void) async {
        guard !wifiBusy else { return }
        wifiBusy = true
        defer { wifiBusy = false }
        do {
            try await work()
            wifiMessage = success
            await scan()
        } catch {
            wifiMessage = error.localizedDescription
        }
    }

    /// While no tablet is ready, try the remembered address now and then (it may be back on the network).
    private func reconnectWiFi() {
        guard status.serial == nil, let address = wifiAddress, !wifiBusy,
              Date.now.timeIntervalSince(lastReconnect) > 15 else { return }
        lastReconnect = .now
        let backend = backend
        Task.detached { try? await backend.connect(address) }
    }

    func choose(device serial: String) {
        preferredSerial = serial
        Task { await scan() }
    }
}
