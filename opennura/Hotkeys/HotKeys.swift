#if os(macOS)
import AppKit
import Carbon.HIToolbox
import Combine

// MARK: - Actions

/// The things a global hotkey can trigger. Each maps to a quick action on the
/// device manager.
enum HotKeyAction: String, CaseIterable, Identifiable, Codable {
    case immersionUp
    case immersionDown
    case toggleAncSocial
    case nextProfile
    case previousProfile
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .immersionUp: return "Immersion up"
        case .immersionDown: return "Immersion down"
        case .toggleAncSocial: return "Toggle ANC / Passthrough"
        case .nextProfile: return "Next profile"
        case .previousProfile: return "Previous profile"
        }
    }
    
    var defaultCombo: KeyCombo {
        // Control+Option + a distinctive key, chosen to avoid common conflicts.
        let mods = UInt32(controlKey) | UInt32(optionKey)
        switch self {
        case .immersionUp: return KeyCombo(keyCode: UInt32(kVK_UpArrow), modifiers: mods)
        case .immersionDown: return KeyCombo(keyCode: UInt32(kVK_DownArrow), modifiers: mods)
        case .toggleAncSocial: return KeyCombo(keyCode: UInt32(kVK_ANSI_A), modifiers: mods)
        case .nextProfile: return KeyCombo(keyCode: UInt32(kVK_RightArrow), modifiers: mods)
        case .previousProfile: return KeyCombo(keyCode: UInt32(kVK_LeftArrow), modifiers: mods)
        }
    }
}

// MARK: - Key combo

/// A key plus Carbon modifier flags, with helpers to display it and to convert
/// from an NSEvent (for the recorder).
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    
    var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        s += KeyCombo.keyName(for: keyCode)
        return s
    }
    
    /// Builds a combo from an NSEvent key-down, or nil if it has no usable
    /// modifiers (we require at least one so global hotkeys don't hijack plain
    /// keys).
    static func from(event: NSEvent) -> KeyCombo? {
        var mods: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        guard mods != 0 else { return nil }
        return KeyCombo(keyCode: UInt32(event.keyCode), modifiers: mods)
    }
    
    static func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        default: return "key \(keyCode)"
        }
    }
}

// MARK: - Settings (persisted)

/// Observable hotkey configuration, persisted to UserDefaults. Editing it from
/// the settings screen republishes so the app can re-register the hotkeys.
final class HotKeySettings: ObservableObject {
    @Published var enabled: Bool {
        didSet { save() }
    }
    @Published var combos: [HotKeyAction: KeyCombo] {
        didSet { save() }
    }
    
    private static let enabledKey = "hotkeys.enabled"
    private static let combosKey = "hotkeys.combos"
    
    init() {
        let defaults = UserDefaults.standard
        self.enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        
        var loaded: [HotKeyAction: KeyCombo] = [:]
        if let data = defaults.data(forKey: Self.combosKey),
           let decoded = try? JSONDecoder().decode([String: KeyCombo].self, from: data) {
            for (key, value) in decoded {
                if let action = HotKeyAction(rawValue: key) { loaded[action] = value }
            }
        }
        // Fill any missing actions with their defaults.
        for action in HotKeyAction.allCases where loaded[action] == nil {
            loaded[action] = action.defaultCombo
        }
        self.combos = loaded
    }
    
    func combo(for action: HotKeyAction) -> KeyCombo {
        combos[action] ?? action.defaultCombo
    }
    
    func resetToDefaults() {
        var d: [HotKeyAction: KeyCombo] = [:]
        for action in HotKeyAction.allCases { d[action] = action.defaultCombo }
        combos = d
    }
    
    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(enabled, forKey: Self.enabledKey)
        var encodable: [String: KeyCombo] = [:]
        for (action, combo) in combos { encodable[action.rawValue] = combo }
        if let data = try? JSONEncoder().encode(encodable) {
            defaults.set(data, forKey: Self.combosKey)
        }
    }
}

// MARK: - Carbon global hotkey center

/// Registers system-wide hotkeys via Carbon (no Accessibility permission
/// required) and routes presses to per-action handlers.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private init() {}
    
    private var handlers: [HotKeyAction: @MainActor () -> Void] = [:]
    private var idToAction: [UInt32: HotKeyAction] = [:]
    private var refs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1
    private let signature: OSType = 0x4E555241 // "NURA"
    
    /// Installs the one-shot Carbon event handler and the action closures. The
    /// handler is a non-capturing literal closure (the only form, besides a
    /// plain func reference, that Swift can turn into a C function pointer).
    func install(handlers: [HotKeyAction: @MainActor () -> Void]) {
        self.handlers = handlers
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, _) -> OSStatus in
                var hkID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                if status == noErr {
                    let id = hkID.id
                    Task { @MainActor in HotKeyCenter.shared.handle(id: id) }
                }
                return noErr
            },
            1, &spec, nil, &eventHandler
        )
    }
    
    /// Re-registers all hotkeys to match the given settings.
    func apply(_ settings: HotKeySettings) {
        unregisterAll()
        guard settings.enabled else { return }
        for action in HotKeyAction.allCases {
            register(action: action, combo: settings.combo(for: action))
        }
    }
    
    private func register(action: HotKeyAction, combo: KeyCombo) {
        let id = nextID
        nextID += 1
        idToAction[id] = action
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs.append(ref) }
    }
    
    private func unregisterAll() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        idToAction.removeAll()
    }
    
    /// Called from the Carbon callback (already hopped to the main actor).
    func handle(id: UInt32) {
        guard let action = idToAction[id], let handler = handlers[action] else { return }
        handler()
    }
}

#endif
