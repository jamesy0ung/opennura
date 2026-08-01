import SwiftUI

struct ContentView: View {
    @ObservedObject var device: NuraDeviceManager
    #if os(macOS)
    @EnvironmentObject var hotkeys: HotKeySettings
    #endif

    var body: some View {
        TabView {
            Group {
                #if os(iOS)
                NavigationStack {
                    ControlTab(device: device)
                        .navigationTitle("OpenNura")
                        .navigationBarTitleDisplayMode(.inline)
                }
                #else
                ControlTab(device: device)
                #endif
            }
            .tabItem { Label("Control", systemImage: "headphones") }
            Group {
                #if os(iOS)
                NavigationStack {
                    DeviceKeysView()
                        .navigationTitle("Devices")
                        .navigationBarTitleDisplayMode(.inline)
                }
                #else
                DeviceKeysView()
                #endif
            }
            .tabItem { Label("Devices", systemImage: "key") }
            #if os(macOS)
            ShortcutsView(hotkeys: hotkeys)
                .tabItem { Label("Shortcuts", systemImage: "command") }
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 640)
        #endif
    }
}

// MARK: - Control tab

struct ControlTab: View {
    @ObservedObject var device: NuraDeviceManager
    @State private var showLogs = false
    @State private var showProvisioning = false
    @State private var showButtons = false
    @State private var showCompare = false
    @State private var renameTarget: Int?
    @State private var renameText = ""
    @State private var showRename = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                headerCard

                if device.phase.isReady {
                    soundCard
                    noiseCard
                    immersionCard
                    if !device.state.profileNames.isEmpty { profilesCard }
                    if device.supportsVisualisation { profileShapeCard }
                    customiseCard
                    deviceInfoCard
                } else {
                    setupCard
                }

                logsCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.10), Color.clear],
                startPoint: .top, endPoint: .center
            )
            .ignoresSafeArea()
        )
        .sheet(isPresented: $showProvisioning) {
            ProvisioningView(device: device, provisioning: device.provisioning)
        }
        .sheet(isPresented: $showButtons) {
            ButtonRemapView(device: device)
        }
        .sheet(isPresented: $showCompare) {
            ProfileCompareView(device: device)
        }
        .alert("Rename profile", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let id = renameTarget { device.renameProfile(id, to: renameText) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This name is stored in the app only; it isn't written to the headphones.")
        }
    }

    // MARK: Header

    private var headerCard: some View {
        Card {
            HStack(spacing: 16) {
                if device.phase.isReady, let battery = device.state.battery {
                    BatteryRing(percentage: battery.batteryPercentage, isCharging: battery.isCharging)
                } else {
                    Image(systemName: "headphones")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                        .frame(width: 76, height: 76)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(device.connectedDeviceName)
                        .font(.title2.weight(.bold))
                    StatusBadge(phase: device.phase)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 8) {
                    if device.phase.isIdle {
                        Button("Connect") { device.connect() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Disconnect", role: .destructive) { device.disconnect() }
                            .buttonStyle(.bordered)
                    }
                    #if os(macOS)
                    Picker("Transport", selection: $device.macBluetoothTransport) {
                        ForEach(MacBluetoothTransport.allCases) { transport in
                            Text(transport.rawValue).tag(transport)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.mini)
                    .frame(width: 150)
                    .disabled(!device.phase.isIdle)

                    if device.macBluetoothTransport == .rfcomm {
                        Toggle(isOn: $device.autoDisconnectAudio) {
                            Text("Auto-disconnect audio")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                    }
                    #endif
                }
            }
        }
    }

    // MARK: Setup (not connected)

    private var setupCard: some View {
        Card("Get started", systemImage: "sparkles") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Connect to control your Nuraphone. If you don't have your device key yet, recover it from Nura with your account.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Button {
                    showProvisioning = true
                } label: {
                    Label("Recover key from Nura", systemImage: "key.horizontal")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                #if os(macOS)
                Label("With auto-disconnect on (top right), connecting briefly drops the headphones' audio, then you can play again.", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                #endif
            }
        }
    }

    // MARK: Sound

    private var soundCard: some View {
        Card("Sound", systemImage: "music.note", accent: .pink) {
            Picker("Sound mode", selection: Binding(
                get: { device.state.personalisationMode },
                set: { newValue in device.setSoundMode(newValue) }
            )) {
                ForEach(NuraPersonalisationMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    // MARK: Noise control

    private var noiseCard: some View {
        Card("Noise control", systemImage: "ear", accent: .blue) {
            Picker("Noise mode", selection: Binding(
                get: { device.state.anc?.mode ?? .off },
                set: { newValue in device.setAncMode(newValue) }
            )) {
                ForEach(NuraAncMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    // MARK: Immersion

    private var immersionCard: some View {
        Card("Immersion", systemImage: "waveform.path", accent: .orange) {
            ImmersionSlider(current: device.state.immersionLevel) {
                device.setImmersion($0)
            }
        }
    }

    // MARK: Profiles

    private var profilesCard: some View {
        Card("Hearing profiles", systemImage: "person.crop.circle", accent: .purple) {
            VStack(spacing: 4) {
                profileRow(id: 0)
                Divider()
                profileRow(id: 1)
                Divider()
                profileRow(id: 2)
            }
        }
    }

    @ViewBuilder
    private func profileRow(id: Int) -> some View {
        if device.isProfilePopulated(id) {
            populatedProfileRow(id: id)
        } else {
            emptyProfileRow(id: id)
        }
    }

    private func populatedProfileRow(id: Int) -> some View {
        let isCurrent = device.state.profileId == id
        return HStack(spacing: 8) {
            Button {
                device.selectProfile(id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                    Text(device.displayProfileName(id)).foregroundStyle(.primary)
                    if let detail = device.profileNameDetail(id) {
                        Text("(\(detail))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)

            Button {
                renameTarget = id
                renameText = device.displayProfileName(id)
                showRename = true
            } label: {
                Image(systemName: "pencil")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Rename \(device.displayProfileName(id))")
        }
    }

    private func emptyProfileRow(id: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.dashed")
                .foregroundStyle(.tertiary)
            Text("Profile \(id + 1)")
                .foregroundStyle(.tertiary)
            Text("(empty)")
                .font(.callout)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    // MARK: Profile shape (visualisation)

    private var profileShapeCard: some View {
        let currentId = device.state.profileId ?? 0
        let vis = device.state.visualisations[currentId]
        return Card("Profile shape", systemImage: "waveform.path.ecg", accent: .indigo) {
            VStack(alignment: .leading, spacing: 12) {
                Text("The hearing signature for \(device.displayProfileName(currentId)). This reads stored values from the headphones and plays nothing.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let vis, !vis.isEmpty {
                    ProfileVisualisationView(visualisation: vis)
                    if !vis.valid {
                        Label("The headphones reported this profile has no signature data yet.",
                              systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    device.refreshVisualisation(profileId: currentId)
                } label: {
                    Label(vis == nil ? "Show shape" : "Reload shape",
                          systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    showCompare = true
                } label: {
                    Label("Compare all profiles", systemImage: "chart.line.uptrend.xyaxis")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
    }

    // MARK: Customise

    private var customiseCard: some View {
        Card("Customise", systemImage: "slider.horizontal.3", accent: .teal) {
            Button {
                showButtons = true
            } label: {
                HStack {
                    Label("Touch buttons", systemImage: "hand.tap")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Device info

    @ViewBuilder
    private var deviceInfoCard: some View {
        if let info = device.state.deviceInfo {
            Card("Device", systemImage: "info.circle") {
                VStack(spacing: 8) {
                    infoRow("Serial", "\(info.serialNumber)")
                    Divider()
                    infoRow("Firmware", "\(info.firmwareVersion)")
                }
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.footnote.monospaced()).foregroundStyle(.secondary)
        }
    }

    // MARK: Logs

    private var logsCard: some View {
        Card {
            DisclosureGroup("Activity log", isExpanded: $showLogs) {
                LogView(logs: device.logs)
                    .padding(.top, 8)
            }
            .font(.subheadline.weight(.medium))
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        let view = ContentView(device: NuraDeviceManager())
        #if os(macOS)
        return view.environmentObject(HotKeySettings())
        #else
        return view
        #endif
    }
}
