import SwiftUI
import UniformTypeIdentifiers

struct DeviceKeysView: View {
    @State private var devices: [NuraDeviceConfigEntry] = []
    @State private var editingEntry: NuraDeviceConfigEntry?
    @State private var showEditor = false
    @State private var showImporter = false
    @State private var importError: String?
    #if os(iOS)
    @State private var shareItem: ShareItem?
    #endif
    private let configStore = NuraConfigStore()

    var body: some View {
        NavigationStack {
            List {
                if devices.isEmpty {
                    Text("No devices added. Add a device's serial number and key to connect to it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(devices, id: \.deviceSerial) { entry in
                    Button {
                        editingEntry = entry
                        showEditor = true
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.friendlyName.isEmpty ? "Serial \(entry.deviceSerial)" : entry.friendlyName)
                                .foregroundStyle(.primary)
                            Text("Serial \(entry.deviceSerial)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    #if os(iOS)
                    .swipeActions(edge: .leading) {
                        Button {
                            export([entry])
                        } label: {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .tint(.blue)
                    }
                    #endif
                }
                .onDelete(perform: delete)
            }
            .navigationTitle("Devices")
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editingEntry = nil
                        showEditor = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                #if os(iOS)
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        export(devices)
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(devices.isEmpty)
                }
                #endif
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showImporter = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
            }
            .onAppear(perform: reload)
            .sheet(isPresented: $showEditor, onDismiss: reload) {
                DeviceEntryEditor(entry: editingEntry, onSave: save)
            }
            #if os(iOS)
            .sheet(item: $shareItem) { wrapped in
                ShareSheet(items: [wrapped.url])
            }
            #endif
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
                importDevices(from: result)
            }
            .alert(
                "Import Failed",
                isPresented: Binding(
                    get: { importError != nil },
                    set: { if !$0 { importError = nil } }
                )
            ) {
                Button("OK") { importError = nil }
            } message: {
                Text(importError ?? "")
            }
        }
    }

    private func reload() {
        devices = configStore.load().devices
    }

    private func delete(at offsets: IndexSet) {
        var config = configStore.load()
        let serialsToRemove = Set(offsets.map { devices[$0].deviceSerial })
        config.devices.removeAll { serialsToRemove.contains($0.deviceSerial) }
        configStore.save(config)
        reload()
    }

    private func save(_ entry: NuraDeviceConfigEntry) {
        var config = configStore.load()
        config.upsertDevice(entry)
        configStore.save(config)
        reload()
    }

    // MARK: - Export

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

    // MARK: - Import

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
                for entry in imported {
                    config.upsertDevice(entry)
                }
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

private struct DeviceEntryEditor: View {
    @Environment(\.dismiss) private var dismiss
    let entry: NuraDeviceConfigEntry?
    let onSave: (NuraDeviceConfigEntry) -> Void

    @State private var friendlyName: String
    @State private var deviceSerial: String
    @State private var keyHex: String
    @State private var errorMessage: String?

    init(entry: NuraDeviceConfigEntry?, onSave: @escaping (NuraDeviceConfigEntry) -> Void) {
        self.entry = entry
        self.onSave = onSave
        _friendlyName = State(initialValue: entry?.friendlyName ?? "")
        _deviceSerial = State(initialValue: entry?.deviceSerial ?? "")
        let keyBytes = entry?.getDeviceKeyBytes() ?? []
        _keyHex = State(initialValue: keyBytes.map { String(format: "%02x", $0) }.joined())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Device") {
                    TextField("Name (optional)", text: $friendlyName)
                    TextField("Serial number", text: $deviceSerial)
                        #if !os(macOS)
                        .keyboardType(.numberPad)
                        #endif
                }
                Section("Key") {
                    TextField("Device key (32 hex characters)", text: $keyHex)
                        .font(.footnote.monospaced())
                        #if !os(macOS)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        #endif
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(entry == nil ? "Add Device" : "Edit Device")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: trySave)
                }
            }
        }
    }

    private func trySave() {
        let serial = deviceSerial.trimmingCharacters(in: .whitespaces)
        guard !serial.isEmpty else {
            errorMessage = "Serial number is required"
            return
        }
        guard let keyBytes = parseHexKey(keyHex), keyBytes.count == 16 else {
            errorMessage = "Key must be 32 hex characters (16 bytes)"
            return
        }
        var result = entry ?? NuraDeviceConfigEntry(
            deviceSerial: serial,
            deviceKey: ""
        )
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

#Preview {
    DeviceKeysView()
}
