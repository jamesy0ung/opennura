import SwiftUI
import UniformTypeIdentifiers

struct DeviceKeysView: View {
    @State private var devices: [NuraDeviceConfigEntry] = []
    @State private var editorTarget: EditorTarget?
    @State private var showImporter = false
    @State private var importError: String?
    #if os(iOS)
    @State private var shareItem: ShareItem?
    #endif
    private let configStore = NuraConfigStore()

    /// What the editor sheet is editing. Using an Identifiable item (rather than
    /// a separate isPresented flag) guarantees the sheet is built with the
    /// chosen entry on the first open, not a stale value.
    private enum EditorTarget: Identifiable {
        case add
        case edit(NuraDeviceConfigEntry)
        var id: String {
            switch self {
            case .add: return "__add__"
            case .edit(let entry): return entry.deviceSerial
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header

                if devices.isEmpty {
                    emptyCard
                } else {
                    ForEach(devices, id: \.deviceSerial) { entry in
                        deviceCard(entry)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .background(
            LinearGradient(colors: [Color.accentColor.opacity(0.10), Color.clear],
                           startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
        )
        .onAppear(perform: reload)
        .sheet(item: $editorTarget, onDismiss: reload) { target in
            switch target {
            case .add:
                DeviceEntryEditor(entry: nil, onSave: save, onDelete: delete(serial:))
            case .edit(let entry):
                DeviceEntryEditor(entry: entry, onSave: save, onDelete: delete(serial:))
            }
        }
        #if os(iOS)
        .sheet(item: $shareItem) { wrapped in ShareSheet(items: [wrapped.url]) }
        #endif
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            importDevices(from: result)
        }
        .alert("Import failed", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    // MARK: - Pieces

    private var header: some View {
        #if os(iOS)
        HStack {
            Text(devices.isEmpty ? "Your saved device keys" : "\(devices.count) saved \(devices.count == 1 ? "device" : "devices")")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                showImporter = true
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .labelStyle(.iconOnly)
            .accessibilityLabel("Import devices")
            Button {
                editorTarget = .add
            } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        #else
        HStack {
            Text("Devices")
                .font(.largeTitle.weight(.bold))
            Spacer()
            Button {
                showImporter = true
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .help("Import from JSON")
            Button {
                editorTarget = .add
            } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        #endif
    }

    private var emptyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("No devices yet", systemImage: "key.horizontal")
                    .font(.headline)
                Text("Recover a key from the Control tab, or add a device's serial and key by hand with the Add button.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func deviceCard(_ entry: NuraDeviceConfigEntry) -> some View {
        let hasName = !entry.friendlyName.isEmpty
        let hasKey = entry.getDeviceKeyBytes() != nil
        return Button {
            editorTarget = .edit(entry)
        } label: {
            Card {
                HStack(spacing: 14) {
                    Image(systemName: "headphones")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 44, height: 44)
                        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color.accentColor.opacity(0.15)))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(hasName ? entry.friendlyName : "Nuraphone")
                            .font(.headline)
                        Text("Serial \(entry.deviceSerial)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Label(hasKey ? "Key saved" : "No key",
                              systemImage: hasKey ? "lock.fill" : "lock.open")
                            .font(.caption)
                            .foregroundStyle(hasKey ? .green : .orange)
                    }

                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        #if os(iOS)
        .swipeActions(edge: .leading) {
            Button { export([entry]) } label: { Label("Share", systemImage: "square.and.arrow.up") }
                .tint(.blue)
        }
        #endif
        .contextMenu {
            #if os(iOS)
            Button { export([entry]) } label: { Label("Share", systemImage: "square.and.arrow.up") }
            #endif
            Button(role: .destructive) { delete(serial: entry.deviceSerial) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Data

    private func reload() {
        devices = configStore.load().devices
    }

    private func delete(serial: String) {
        var config = configStore.load()
        config.devices.removeAll { $0.deviceSerial == serial }
        configStore.save(config)
        configStore.forgetDeviceKey(serial: serial)
        reload()
    }

    private func save(_ entry: NuraDeviceConfigEntry) {
        var config = configStore.load()
        config.upsertDevice(entry)
        configStore.save(config)
        reload()
    }

    #if os(iOS)
    private func export(_ entries: [NuraDeviceConfigEntry]) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(entries)
            let name = entries.count == 1 ? "nura-device-\(entries[0].deviceSerial).json" : "nura-devices.json"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            shareItem = ShareItem(url: url)
        } catch {
            importError = "Could not export: \(error.localizedDescription)"
        }
    }
    #endif

    private func importDevices(from result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
        case .success(let url):
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                let imported: [NuraDeviceConfigEntry]
                if let list = try? decoder.decode([NuraDeviceConfigEntry].self, from: data) {
                    imported = list
                } else {
                    imported = [try decoder.decode(NuraDeviceConfigEntry.self, from: data)]
                }
                guard !imported.isEmpty else {
                    importError = "No devices found in file"
                    return
                }
                var config = configStore.load()
                for entry in imported { config.upsertDevice(entry) }
                configStore.save(config)
                reload()
            } catch {
                importError = "Could not read file: \(error.localizedDescription)"
            }
        }
    }
}

#if os(iOS)
private struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}
#endif

// MARK: - Add / edit sheet

private struct DeviceEntryEditor: View {
    @Environment(\.dismiss) private var dismiss
    let entry: NuraDeviceConfigEntry?
    let onSave: (NuraDeviceConfigEntry) -> Void
    let onDelete: (String) -> Void

    @State private var friendlyName: String
    @State private var deviceSerial: String
    @State private var keyHex: String
    @State private var errorMessage: String?
    @State private var revealKey = false
    @State private var didCopy = false

    init(entry: NuraDeviceConfigEntry?,
         onSave: @escaping (NuraDeviceConfigEntry) -> Void,
         onDelete: @escaping (String) -> Void) {
        self.entry = entry
        self.onSave = onSave
        self.onDelete = onDelete
        _friendlyName = State(initialValue: entry?.friendlyName ?? "")
        _deviceSerial = State(initialValue: entry?.deviceSerial ?? "")
        let keyBytes = entry?.getDeviceKeyBytes() ?? []
        _keyHex = State(initialValue: keyBytes.map { String(format: "%02x", $0) }.joined())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field("Name (optional)") {
                        TextField("e.g. My Nuraphone", text: $friendlyName)
                            .textFieldStyle(.roundedBorder)
                    }
                    field("Serial number") {
                        TextField("Numeric serial", text: $deviceSerial)
                            .textFieldStyle(.roundedBorder)
                            #if !os(macOS)
                            .keyboardType(.numberPad)
                            #endif
                    }
                    keyField
                    if let errorMessage {
                        Text(errorMessage).font(.callout).foregroundStyle(.red)
                    }
                    if entry != nil {
                        Button(role: .destructive) {
                            onDelete(deviceSerial)
                            dismiss()
                        } label: {
                            Label("Delete device", systemImage: "trash")
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(20)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(entry == nil ? "Add device" : "Edit device")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: trySave) }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 420)
        #endif
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private var keyField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Device key").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if revealKey {
                TextField("32 hex characters", text: $keyHex)
                    .textFieldStyle(.roundedBorder)
                    .font(.footnote.monospaced())
                    #if !os(macOS)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    #endif
            } else {
                Text(keyHex.isEmpty ? "Not set" : maskedKey)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            }
            HStack {
                Button {
                    revealKey.toggle()
                } label: {
                    Label(revealKey ? "Hide" : "Reveal", systemImage: revealKey ? "eye.slash" : "eye")
                }
                Spacer()
                Button {
                    copyKey()
                } label: {
                    Label(didCopy ? "Copied" : "Copy key", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                }
                .disabled(keyHex.isEmpty)
            }
            .font(.footnote)
            .buttonStyle(.borderless)
            Text("Back this up somewhere safe. Nura's servers may go offline, and this key is what lets the app control your headphones.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var maskedKey: String {
        let clean = keyHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 8 else { return String(repeating: "•", count: clean.count) }
        return "\(clean.prefix(4))••••••••••••••••••••••••\(clean.suffix(4))"
    }

    private func copyKey() {
        let value = keyHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #else
        UIPasteboard.general.string = value
        #endif
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { didCopy = false }
    }

    private func trySave() {
        let serial = deviceSerial.trimmingCharacters(in: .whitespaces)
        guard !serial.isEmpty else { errorMessage = "Serial number is required"; return }
        guard let keyBytes = parseHexKey(keyHex), keyBytes.count == 16 else {
            errorMessage = "Key must be 32 hex characters (16 bytes)"
            return
        }
        var result = entry ?? NuraDeviceConfigEntry(deviceSerial: serial, deviceKey: "")
        result.friendlyName = friendlyName
        result.deviceSerial = serial
        result = result.withDeviceKeyBytes(keyBytes)
        onSave(result)
        dismiss()
    }
}

private func parseHexKey(_ s: String) -> [UInt8]? {
    let cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "")
    guard cleaned.count == 32 else { return nil }
    var bytes: [UInt8] = []
    var idx = cleaned.startIndex
    while idx < cleaned.endIndex {
        let next = cleaned.index(idx, offsetBy: 2)
        guard let b = UInt8(cleaned[idx..<next], radix: 16) else { return nil }
        bytes.append(b)
        idx = next
    }
    return bytes
}

struct DeviceKeysView_Previews: PreviewProvider {
    static var previews: some View {
        DeviceKeysView()
    }
}
