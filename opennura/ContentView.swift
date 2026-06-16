import SwiftUI

struct ContentView: View {
    @StateObject private var ble = NuraBLEManager()
    @State private var showLogs = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                connectSection
                Divider()
                immersionSection
                Divider()
                socialSection
                Divider()
                soundSection
                Divider()
                logsSection
            }
            .padding()
        }
        #if os(macOS)
            .frame(minWidth: 520, minHeight: 440)
        #endif
    }

    // MARK: - Sections

    private var headerSection: some View {
        HStack(alignment: .center) {
            Text("OpenNura").font(.largeTitle.bold())
            Spacer()
            StatusBadge(phase: ble.phase)
        }
    }

    private var connectSection: some View {
        HStack(spacing: 12) {
            Button("Connect") { ble.connect() }
                .buttonStyle(.borderedProminent)
                .disabled(!ble.phase.isIdle)
            Button("Disconnect") { ble.disconnect() }
                .buttonStyle(.bordered)
                .disabled(ble.phase.isIdle)
        }
    }

    private var immersionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "waveform").foregroundStyle(.tint)
                Text("Immersion").font(.headline)
                Text("(current: \(ble.immersionLevel))")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ImmersionButtons(current: ble.immersionLevel) {
                ble.setImmersion($0)
            }
        }
        .disabled(!ble.phase.isReady)
    }

    private var socialSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "ear").foregroundStyle(.tint)
                Text("Social Mode").font(.headline)
            }
            HStack(spacing: 12) {
                socialButton(
                    label: "Social ON",
                    active: ble.socialMode,
                    tint: .green
                ) {
                    ble.setSocialMode(true)
                }
                socialButton(
                    label: "Social OFF",
                    active: !ble.socialMode,
                    tint: .blue
                ) {
                    ble.setSocialMode(false)
                }
            }
        }
        .disabled(!ble.phase.isReady)
    }

    @ViewBuilder
    private func socialButton(
        label: String,
        active: Bool,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        if active {
            Button(label, action: action).buttonStyle(.borderedProminent).tint(
                tint
            )
        } else {
            Button(label, action: action).buttonStyle(.bordered).tint(tint)
        }
    }

    private var soundSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "music.note").foregroundStyle(.tint)
                Text("Sound Mode").font(.headline)
            }
            HStack(spacing: 12) {
                ForEach(SoundMode.allCases) { mode in
                    soundModeButton(mode)
                }
            }
        }
        .disabled(!ble.phase.isReady)
    }

    @ViewBuilder
    private func soundModeButton(_ mode: SoundMode) -> some View {
        if ble.soundMode == mode {
            Button(mode.rawValue) { ble.setSoundMode(mode) }.buttonStyle(
                .borderedProminent
            )
        } else {
            Button(mode.rawValue) { ble.setSoundMode(mode) }.buttonStyle(
                .bordered
            )
        }
    }

    private var logsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $showLogs) {
                HStack {
                    Image(systemName: "text.alignleft")
                    Text("Logs")
                }
            }
            .toggleStyle(.button)
            .buttonStyle(.bordered)

            if showLogs {
                LogView(logs: ble.logs)
            }
        }
    }
}

// MARK: - Status badge

struct StatusBadge: View {
    let phase: ConnectionPhase

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(dotColor).frame(width: 10, height: 10)
            Text(phase.label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
    }

    private var dotColor: Color {
        switch phase {
        case .ready: return .green
        case .failed: return .red
        case .idle: return .gray
        default: return .orange
        }
    }
}

// MARK: - Immersion level buttons (-2...4)

struct ImmersionButtons: View {
    let current: Int
    let onSelect: (Int) -> Void
    private let levels = [-2, -1, 0, 1, 2, 3, 4]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(levels, id: \.self) { level in
                levelButton(level)
            }
        }
    }

    @ViewBuilder
    private func levelButton(_ level: Int) -> some View {
        let title = level >= 0 ? "+\(level)" : "\(level)"
        let tint = levelTint(level)
        if level == current {
            Button(title) { onSelect(level) }.buttonStyle(.borderedProminent)
                .tint(tint)
        } else {
            Button(title) { onSelect(level) }.buttonStyle(.bordered).tint(tint)
        }
    }

    private func levelTint(_ level: Int) -> Color {
        switch level {
        case 4, 3: return .purple
        case 2, 1: return .blue
        case 0: return .gray
        default: return .orange
        }
    }
}

// MARK: - Log view

struct LogView: View {
    let logs: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Spacer()
                Button("Copy All") { copyAll() }
                    .font(.caption)
                    .buttonStyle(.bordered)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(logs.indices, id: \.self) { i in
                            Text(logs[i])
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .id(i)
                        }
                    }
                    .padding(8)
                }
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .frame(minHeight: 180, maxHeight: 320)
                .onChange(of: logs.count) { _, _ in
                    if let last = logs.indices.last {
                        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
        }
    }

    private func copyAll() {
        let text = logs.joined(separator: "\n")
        #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        #else
            UIPasteboard.general.string = text
        #endif
    }
}

#Preview {
    ContentView()
}
