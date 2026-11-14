import AppKit
import SwiftUI
import AndroidFilesKit

// AndroidFiles: shows the Android tablet (USB or Wi-Fi, through adb) as a disk in Finder.
// It lives in the menu bar and has no window of its own, only Settings.
//   AndroidFiles                                   the app
//   ADB_PATH=<path> AndroidFiles                   use another adb
//   APP_STORE=/tmp/<dir> AndroidFiles              a pretend tablet (<dir>/device), never real files
//   APP_DEVICE_STATE=none|unauthorized|offline|noadb   with APP_STORE: show that tablet state
//   APP_SEED=1                                     with APP_STORE: fill the pretend tablet with sample files
//   APP_FINDER=1                                   with APP_STORE: show the pretend tablet as a volume in Finder
//   ANDROIDFILES_HTTP_LOG=1                        print every request Finder makes
//   APP_ACCENT=<id> AndroidFiles                   run with another accent from Theme.all (UI/Theme.swift)

@main
struct AndroidFilesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            TabletMenu(model: model)
        } label: {
            Image(systemName: model.menuSymbol)
                .accessibilityLabel("AndroidFiles: \(model.statusLine)")
        }

        Settings {
            SettingsView()
                .environment(model)
                .themed()
        }
        .windowResizability(.contentSize)
    }
}

/// The menu under the menu bar icon: what the tablet is doing, and the few things to do about it.
struct TabletMenu: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(model.statusLine)
        if let error = model.finderError { Text(error) }
        if model.devices.filter({ $0.state == .ready }).count > 1 {
            Picker("Tablet", selection: Binding(get: { model.status.serial ?? "" }, set: { model.choose(device: $0) })) {
                ForEach(model.devices.filter { $0.state == .ready }, id: \.serial) { device in
                    Text(device.model ?? device.serial).tag(device.serial)
                }
            }
        }
        Divider()
        Button("Open in Finder") { Task { await model.revealInFinder() } }
            .keyboardShortcut("o")
            .disabled(!model.isDeviceReady)
        Button("Eject") { model.eject() }
            .keyboardShortcut("e")
            .disabled(model.finderPath == nil)
        Divider()
        Button("Settings…") {
            // A menu bar app is not in front: bring the window to the person.
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Button("Quit AndroidFiles") { AppDelegate.quit() }
            .keyboardShortcut("q")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var termination: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `kill` quits like the menu does, so the Finder volume is removed on the way out.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { AppDelegate.quit() }
        source.resume()
        termination = source
        // The menu bar only: no Dock icon, no window.
        NSApp.setActivationPolicy(.accessory)
        SeedData.prepareIfRequested()
        AppModel.shared.startMonitoring()
    }

    /// Opening the app again (Spotlight, Launchpad) opens the tablet in Finder: there is no window to show.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        Task { await AppModel.shared.revealInFinder() }
        return false
    }

    /// Quit from the menu or by `kill`: the volume goes the orderly way first, so empty files made
    /// a moment ago are written. Not through `applicationShouldTerminate` and `.terminateLater`:
    /// the wait it starts runs inside the main queue's own block, where no main-actor task can run.
    static func quit() {
        Task {
            await AppModel.shared.eject().value
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Finder must not keep a volume whose app is gone.
        FinderVolume.unmountAll(in: FinderVolume.folder)
    }
}
