import SwiftUI

struct ContentView: View {
    @StateObject private var device = NuraDeviceManager()

    var body: some View {
        TabView {
            DeviceTab(device: device)
                .tabItem {
                    Label("Device", systemImage: "headphones")
                }
            DeviceKeysView()
                .tabItem {
                    Label("Devices", systemImage: "key")
                }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 500)
        #endif
    }
}

// MARK: - Device Tab

struct DeviceTab: View {
    @ObservedObject var device: NuraDeviceManager
    @State private var showLogs = false

    var body: some View {
        NavigationStack {
            List {
                connectionSection
                if device.phase.isReady {
                    batterySection
                    controlsSection
                    profilesSection
                    deviceInfoSection
                }
                logsSection
            }
            .navigationTitle("OpenNura")
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
        }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        Section {
            HStack {
                StatusBadge(phase: device.phase)
                Spacer()
                if device.phase.isIdle {
                    Button("Connect") { device.connect() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else {
                    Button("Disconnect", role: .destructive) { device.disconnect() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Battery

    @ViewBuilder
    private var batterySection: some View {
        if let battery = device.state.battery {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label {
                            Text("Battery")
                        } icon: {
                            Image(systemName: batteryIcon(battery))
                                .foregroundStyle(batteryColor(battery))
                        }
                        Spacer()
                        HStack(spacing: 4) {
                            Text("\(battery.batteryPercentage)%")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                            if battery.isCharging {
                                Image(systemName: "bolt.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption)
                            }
                        }
                    }
                    ProgressView(value: Double(battery.batteryPercentage), total: 100)
                        .tint(batteryColor(battery))
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Controls

    private var controlsSection: some View {
        Section("Controls") {
            VStack(alignment: .leading, spacing: 6) {
                Label("Immersion", systemImage: "waveform.path")
                ImmersionSlider(current: device.state.immersionLevel) {
                    device.setImmersion($0)
                }
            }
            .padding(.vertical, 4)

            Toggle(isOn: Binding(
                get: { device.state.ancEnabled },
                set: { device.setAncEnabled($0) }
            )) {
                Label("Active Noise Cancellation", systemImage: "ear.trianglebadge.exclamationmark")
            }

            Toggle(isOn: Binding(
                get: { device.state.passthroughEnabled },
                set: { device.setSocialMode($0) }
            )) {
                Label("Social Mode", systemImage: "ear")
            }

            HStack {
                Label("Sound", systemImage: "music.note")
                Spacer()
                Picker("", selection: Binding(
                    get: { device.state.personalisationMode },
                    set: { device.setSoundMode($0) }
                )) {
                    ForEach(NuraPersonalisationMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
            }

            if let spatial = device.state.spatialEnabled {
                Toggle(isOn: Binding(
                    get: { spatial },
                    set: { device.setSpatialEnabled($0) }
                )) {
                    Label("Spatial Audio", systemImage: "spatial.audio")
                }
            }
        }
    }

    // MARK: - Profiles

    @ViewBuilder
    private var profilesSection: some View {
        if !device.state.profileNames.isEmpty {
            Section("Profiles") {
                profileRow(id: 0)
                profileRow(id: 1)
                profileRow(id: 2)
            }
        }
    }

    private func profileRow(id: Int) -> some View {
        let name = device.state.profileNames[id] ?? "Profile \(id + 1)"
        let isCurrent = device.state.profileId == id
        return Button {
            device.selectProfile(id)
        } label: {
            HStack {
                Text(name)
                    .foregroundStyle(.primary)
                Spacer()
                if isCurrent {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .fontWeight(.semibold)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Device Info

    @ViewBuilder
    private var deviceInfoSection: some View {
        if let info = device.state.deviceInfo {
            Section("Device Info") {
                LabeledContent("Serial") {
                    Text("\(info.serialNumber)")
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Firmware") {
                    Text("\(info.firmwareVersion)")
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Logs

    private var logsSection: some View {
        Section {
            DisclosureGroup("Logs", isExpanded: $showLogs) {
                LogView(logs: device.logs)
            }
        }
    }

    // MARK: - Helpers

    private func batteryIcon(_ battery: NuraBatteryStatus) -> String {
        if battery.isCharging { return "battery.100.bolt" }
        switch battery.batteryPercentage {
        case 75...100: return "battery.100"
        case 50..<75: return "battery.75"
        case 25..<50: return "battery.50"
        case 1..<25: return "battery.25"
        default: return "battery.0"
        }
    }

    private func batteryColor(_ battery: NuraBatteryStatus) -> Color {
        if battery.isCharging { return .green }
        switch battery.batteryPercentage {
        case 21...100: return .green
        case 11...20: return .orange
        default: return .red
        }
    }
}

#Preview {
    ContentView()
}
