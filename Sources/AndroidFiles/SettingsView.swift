import SwiftUI
import AndroidFilesKit

/// The Settings window (Command-Comma). One tab per topic, at most about
/// six. Each tab is a grouped Form that sizes to its content, so the
/// window grows to fit and shows no scroll bar it does not need.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            ForEach(SettingsTab.allCases) { tab in
                page(tab)
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
                    .tag(tab)
            }
        }
        .noInitialFocus()
    }

    @ViewBuilder
    private func page(_ tab: SettingsTab) -> some View {
        Form {
            switch tab {
            case .general: GeneralSettings()
            case .appearance: AppearanceSettings()
            }
        }
        .formStyle(.grouped)
        .fitsContent()
        .frame(width: 520)
    }
}

/// The Settings tabs.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, appearance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        }
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section {
            LabeledContent("adb", value: ADB.locate() ?? "Not installed")
            LabeledContent("Tablet", value: model.statusLine)
            LabeledContent("Folder shown", value: AppModel.deviceHome)
            Toggle("Show in Finder", isOn: $model.showInFinder)
            if let error = model.finderError {
                Text(error).foregroundStyle(.secondary)
            }
        } header: {
            Text("Tablet")
        } footer: {
            Text("While the tablet is connected and this app is open, it appears in Finder as a disk, like a USB drive. Eject it there, or in the menu bar, to hide it.")
                .foregroundStyle(.secondary)
        }
        WiFiSettings()
    }
}

/// adb over Wi-Fi: switch the plugged-in tablet over, connect to an address, or pair with a code.
struct WiFiSettings: View {
    @Environment(AppModel.self) private var model
    @ViewState private var address = ""
    @ViewState private var pairAddress = ""
    @ViewState private var code = ""

    var body: some View {
        Section {
            if model.isOnWiFi, let current = model.wifiAddress {
                LabeledContent("Connected over Wi-Fi", value: current)
                Button("Use the Cable Again") { Task { await model.forgetWiFi() } }
                    .disabled(model.wifiBusy)
            } else {
                LabeledContent("Plugged-in tablet") {
                    Button("Switch to Wi-Fi") { Task { await model.switchToWiFi() } }
                        .disabled(model.status.serial == nil || model.wifiBusy)
                }
                LabeledContent("Address") {
                    HStack {
                        TextField("Address", text: $address, prompt: Text(model.wifiAddress ?? "192.168.1.20:5555"))
                            .labelsHidden()
                            .onSubmit(connect)
                        Button("Connect", action: connect)
                            .disabled(model.wifiBusy || (address.isEmpty && model.wifiAddress == nil))
                    }
                }
                LabeledContent("Pair with code") {
                    HStack {
                        TextField("Pairing address", text: $pairAddress, prompt: Text("192.168.1.20:37123"))
                            .labelsHidden()
                        TextField("Code", text: $code, prompt: Text("123456"))
                            .labelsHidden()
                            .frame(width: 72)
                            .onSubmit(pair)
                        Button("Pair", action: pair)
                            .disabled(model.wifiBusy || pairAddress.isEmpty || code.isEmpty)
                    }
                }
            }
            if model.wifiBusy {
                ProgressView().controlSize(.small)
            } else if let message = model.wifiMessage {
                Text(message).foregroundStyle(.secondary)
            }
        } header: {
            Text("Wi-Fi")
        } footer: {
            Text("The tablet and the Mac must be on the same network. After the tablet restarts, plug it in and switch again, or pair with the code under Developer options › Wireless debugging.")
                .foregroundStyle(.secondary)
        }
    }

    private func connect() {
        let target = address.isEmpty ? model.wifiAddress ?? "" : address
        guard !target.isEmpty else { return }
        Task { await model.connect(target) }
    }

    private func pair() {
        guard !pairAddress.isEmpty, !code.isEmpty else { return }
        Task { await model.pair(pairAddress, code: code) }
    }
}
