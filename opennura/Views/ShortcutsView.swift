#if os(macOS)
import SwiftUI
import Carbon.HIToolbox

/// Settings screen for the global hotkeys. Lets the user enable them and record
/// a key combo per action.
struct ShortcutsView: View {
    @ObservedObject var hotkeys: HotKeySettings

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header

                Card(accent: .indigo) {
                    Toggle(isOn: $hotkeys.enabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Global hotkeys").font(.headline)
                            Text("Allow hotkeys to work when the app is not focused.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }

                Card("Shortcuts", systemImage: "command", accent: .teal) {
                    VStack(spacing: 4) {
                        ForEach(HotKeyAction.allCases) { action in
                            rowFor(action)
                            if action != HotKeyAction.allCases.last { Divider() }
                        }
                    }
                    .disabled(!hotkeys.enabled)
                    .opacity(hotkeys.enabled ? 1 : 0.5)
                }

                Button("Reset to defaults") { hotkeys.resetToDefaults() }
                    .buttonStyle(.borderless)
                    .font(.footnote)
            }
            .padding(16)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .background(
            LinearGradient(colors: [Color.accentColor.opacity(0.10), Color.clear],
                           startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
        )
    }

    private var header: some View {
        HStack {
            Text("Shortcuts").font(.largeTitle.weight(.bold))
            Spacer()
        }
    }

    private func rowFor(_ action: HotKeyAction) -> some View {
        HStack {
            Text(action.title)
            Spacer()
            KeyRecorderButton(combo: hotkeys.combo(for: action)) { newCombo in
                hotkeys.combos[action] = newCombo
            }
        }
        .padding(.vertical, 4)
    }
}

/// A button that shows the current combo and, when clicked, records the next
/// modifier+key press.
private struct KeyRecorderButton: View {
    let combo: KeyCombo
    let onRecorded: (KeyCombo) -> Void

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            if recording { stop() } else { start() }
        } label: {
            Text(recording ? "Press keys…" : combo.displayString)
                .font(.body.monospaced())
                .frame(minWidth: 96)
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(recording ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
                return nil
            }
            if let newCombo = KeyCombo.from(event: event) {
                onRecorded(newCombo)
                stop()
                return nil
            }
            return event
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
#endif
