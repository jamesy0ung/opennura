import Foundation

// MARK: - ANC

struct NuraAncState: Equatable {
    var ancEnabled: Bool
    var passthroughEnabled: Bool

    var mode: NuraAncMode {
        passthroughEnabled ? .passthrough : (ancEnabled ? .anc : .off)
    }
}

enum NuraAncMode: String, CaseIterable {
    case off = "Off"
    case anc = "ANC"
    case passthrough = "Passthrough"
}

// MARK: - Battery

struct NuraBatteryStatus: Equatable {
    var batteryVoltageMillivolts: Int
    var batteryLevelRaw: Int
    var batteryPercentage: Int
    var chargerStateRaw: Int
    var chargerVoltageMillivolts: Int
    var chargerLevelRaw: Int
    var ntcVoltageMillivolts: Int
    var ntcLevelRaw: Int

    var isCharging: Bool { chargerStateRaw != 0 }
}

// MARK: - Immersion

enum NuraImmersionLevel: Int, CaseIterable {
    case negative2 = -2
    case negative1 = -1
    case neutral = 0
    case positive1 = 1
    case positive2 = 2
    case positive3 = 3
    case positive4 = 4
}

// MARK: - Sound mode

enum NuraPersonalisationMode: String, CaseIterable, Identifiable {
    case personalised = "Personalised"
    case neutral = "Neutral"
    var id: String { rawValue }
    var byte: UInt8 { self == .personalised ? 0x01 : 0x00 }
}

// MARK: - Button functions

enum NuraButtonFunction: UInt8, CaseIterable, Identifiable {
    case none = 0x00
    case playPauseAndCall = 0x01
    case playPauseOnly = 0x02
    case toggleKickIt = 0x03
    case holdForPassthroughOnOneSide = 0x04
    case holdForPassthroughOnBothSides = 0x05
    case togglePassthroughOnOneSide = 0x06
    case togglePassthroughOnBothSides = 0x07
    case toggleSocial = 0x08
    case toggleGenericModeEnabled = 0x09
    case previousTrack = 0x0A
    case nextTrack = 0x0B
    case volumeUp = 0x0C
    case volumeDown = 0x0D
    case toggleAnc = 0x0E
    case cycleAncPassthrough = 0x0F
    case speakBatteryLevel = 0x10
    case rejectCall = 0x11
    case playPauseAndAnswerCall = 0x12
    case voiceAssistant = 0x13
    case mute = 0x14
    case togglePassthroughAndPause = 0x15
    case kickItUp = 0x16
    case kickItDown = 0x17
    case toggleSpatial = 0x18
    case toggleGamingMode = 0x19

    var id: UInt8 { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .playPauseAndCall: return "Play/Pause & Call"
        case .playPauseOnly: return "Play/Pause"
        case .toggleKickIt: return "Toggle Immersion"
        case .holdForPassthroughOnOneSide: return "Hold Passthrough (1 side)"
        case .holdForPassthroughOnBothSides: return "Hold Passthrough (both)"
        case .togglePassthroughOnOneSide: return "Toggle Passthrough (1 side)"
        case .togglePassthroughOnBothSides: return "Toggle Passthrough (both)"
        case .toggleSocial: return "Toggle Social"
        case .toggleGenericModeEnabled: return "Toggle Generic Mode"
        case .previousTrack: return "Previous Track"
        case .nextTrack: return "Next Track"
        case .volumeUp: return "Volume Up"
        case .volumeDown: return "Volume Down"
        case .toggleAnc: return "Toggle ANC"
        case .cycleAncPassthrough: return "Cycle ANC/Passthrough"
        case .speakBatteryLevel: return "Speak Battery Level"
        case .rejectCall: return "Reject Call"
        case .playPauseAndAnswerCall: return "Play/Pause & Answer"
        case .voiceAssistant: return "Voice Assistant"
        case .mute: return "Mute"
        case .togglePassthroughAndPause: return "Passthrough & Pause"
        case .kickItUp: return "Immersion Up"
        case .kickItDown: return "Immersion Down"
        case .toggleSpatial: return "Toggle Spatial"
        case .toggleGamingMode: return "Toggle Gaming Mode"
        }
    }

    static func fromRawByte(_ value: UInt8) -> NuraButtonFunction {
        NuraButtonFunction(rawValue: value) ?? .none
    }
}

// MARK: - Button configuration

struct NuraButtonConfiguration: Equatable {
    var leftSingleTap: NuraButtonFunction
    var rightSingleTap: NuraButtonFunction
    var leftDoubleTap: NuraButtonFunction?
    var rightDoubleTap: NuraButtonFunction?
    var leftTapAndHold: NuraButtonFunction?
    var rightTapAndHold: NuraButtonFunction?
    var leftTripleTap: NuraButtonFunction?
    var rightTripleTap: NuraButtonFunction?

    func toBytes(supportsDoubleTap: Bool, supportsTripleTap: Bool) -> [UInt8] {
        var bytes: [UInt8] = [leftSingleTap.rawValue, rightSingleTap.rawValue]
        if supportsDoubleTap {
            bytes += [
                (leftDoubleTap ?? .none).rawValue,
                (rightDoubleTap ?? .none).rawValue,
                (leftTapAndHold ?? .none).rawValue,
                (rightTapAndHold ?? .none).rawValue,
            ]
        }
        if supportsTripleTap {
            bytes += [
                (leftTripleTap ?? .none).rawValue,
                (rightTripleTap ?? .none).rawValue,
            ]
        }
        return bytes
    }
}

// MARK: - Dial functions

enum NuraDialFunction: UInt8, CaseIterable, Identifiable {
    case none = 0x00
    case kickit = 0x01
    case anc = 0x02
    case volume = 0x03

    var id: UInt8 { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .kickit: return "Immersion"
        case .anc: return "ANC"
        case .volume: return "Volume"
        }
    }

    static func fromRawByte(_ value: UInt8) -> NuraDialFunction {
        NuraDialFunction(rawValue: value) ?? .none
    }
}

// MARK: - Dial configuration

struct NuraDialConfiguration: Equatable {
    var left: NuraDialFunction
    var right: NuraDialFunction

    func toBytes() -> [UInt8] {
        [left.rawValue, right.rawValue]
    }
}

// MARK: - Kickit state (TWS devices)

struct NuraKickitState: Equatable {
    var rawLevel: Int
    var enabled: Bool
}

// MARK: - Classic kickit params (Nuraphone)

struct NuraClassicKickitParams: Equatable {
    var drcRaw: UInt8
    var lpfRaw: UInt8
    var gainRaw: UInt8

    var immersionLevel: NuraImmersionLevel? {
        switch (drcRaw, lpfRaw, gainRaw) {
        case (0x04, 0x00, 0x02): return .positive4
        case (0x03, 0x00, 0x02): return .positive3
        case (0x02, 0x02, 0x02): return .positive2
        case (0x01, 0x02, 0x02): return .positive1
        case (0x00, 0x04, 0x02): return .neutral
        case (0x00, 0x04, 0x01): return .negative1
        case (0x00, 0x04, 0x00): return .negative2
        default: return nil
        }
    }

    static func from(_ level: NuraImmersionLevel) -> NuraClassicKickitParams {
        switch level {
        case .positive4: return .init(drcRaw: 0x04, lpfRaw: 0x00, gainRaw: 0x02)
        case .positive3: return .init(drcRaw: 0x03, lpfRaw: 0x00, gainRaw: 0x02)
        case .positive2: return .init(drcRaw: 0x02, lpfRaw: 0x02, gainRaw: 0x02)
        case .positive1: return .init(drcRaw: 0x01, lpfRaw: 0x02, gainRaw: 0x02)
        case .neutral: return .init(drcRaw: 0x00, lpfRaw: 0x04, gainRaw: 0x02)
        case .negative1: return .init(drcRaw: 0x00, lpfRaw: 0x04, gainRaw: 0x01)
        case .negative2: return .init(drcRaw: 0x00, lpfRaw: 0x04, gainRaw: 0x00)
        }
    }
}

// MARK: - Device info

struct NuraDeviceInfo: Equatable {
    var serialNumber: Int
    var firmwareVersion: Int
}

// MARK: - Headset indication

enum HeadsetIndicationId: UInt8 {
    case genericModeEnabledChanged = 0
    case cableChanged = 1
    case audioPromptFinished = 2
    case currentProfileChanged = 3
    case kickitEnabledChanged = 4
    case touchButtonPressed = 5
    case ancParametersChanged = 6
    case ancLevelChanged = 7
    case touchDial = 8
    case kickitLevelChanged = 9
}

struct HeadsetIndication {
    var identifier: HeadsetIndicationId
    var value: UInt8
}
