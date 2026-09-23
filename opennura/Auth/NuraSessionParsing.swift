import Foundation

// MARK: - Decoded value navigation helpers
//
// The Nura backend replies with msgpack. `MessagePackLite.deserialize` yields
// nested [String: Any?] maps, [Any?] arrays, Int, String, Bool, Double and
// [UInt8] (binary) values. These helpers mirror the lookups performed by the
// Windows NuraLib parsers (NuraAuthResponseParser / NuraSessionStartResponseParser)
// but operate on the loosely typed values produced here.

enum NuraMsg {
    static func asMap(_ value: Any?) -> [String: Any?]? {
        value as? [String: Any?]
    }
    
    static func asArray(_ value: Any?) -> [Any?]? {
        value as? [Any?]
    }
    
    /// Case-insensitive lookup within a map.
    static func value(_ map: [String: Any?]?, _ key: String) -> Any? {
        guard let map else { return nil }
        if let direct = map[key] { return direct }
        for (k, v) in map where k.caseInsensitiveCompare(key) == .orderedSame {
            return v
        }
        return nil
    }
    
    static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let i as Int: return i
        case let i as Int64 where i >= Int64(Int.min) && i <= Int64(Int.max): return Int(i)
        case let u as UInt64 where u <= UInt64(Int.max): return Int(u)
        case let d as Double: return Int(d)
        case let f as Float: return Int(f)
        case let s as String: return Int(s)
        default: return nil
        }
    }
    
    static func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let b as Bool: return b
        case let s as String: return Bool(s)
        default: return nil
        }
    }
    
    /// Mirrors NuraLib's ConvertToStringValue: strings pass through, and binary
    /// values are base64-encoded (this is how app_enc.key arrives).
    static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let s as String: return s
        case let bytes as [UInt8]: return Data(bytes).base64EncodedString()
        case let data as Data: return data.base64EncodedString()
        default: return nil
        }
    }
    
    /// Returns bytes for a payload node, decoding base64 strings when needed.
    static func bytesValue(_ value: Any?) -> [UInt8]? {
        switch value {
        case let bytes as [UInt8]: return bytes
        case let data as Data: return [UInt8](data)
        case let s as String: return Data(base64Encoded: s).map { [UInt8]($0) }
        default: return nil
        }
    }
}

// MARK: - Session snapshot (usid / asid / app_enc key)

struct NuraAuthSnapshot {
    var userSessionId: Int?
    var appSessionId: Int?
    var appEncKey: String?
    var appEncNonce: String?
}

enum NuraAuthResponseParser {
    
    /// Extracts the session-relevant fields from a decoded response body.
    static func extract(_ body: [String: Any?]?) -> NuraAuthSnapshot {
        guard let body else { return NuraAuthSnapshot() }
        var snap = NuraAuthSnapshot()
        
        snap.userSessionId =
        NuraMsg.intValue(NuraMsg.value(typedActionDetail(body, "user_session_status"), "id")) ??
        findIntInPayload(body, keys: ["user_session_id", "userSessionId", "sessionId", "usid"])
        
        snap.appSessionId =
        NuraMsg.intValue(NuraMsg.value(typedActionDetail(body, "app_session_status"), "id")) ??
        findIntInPayload(body, keys: ["app_session_id", "appSessionId", "asid"])
        
        snap.appEncKey =
        NuraMsg.stringValue(NuraMsg.value(typedActionDetail(body, "app_enc"), "key")) ??
        findStringInPayload(body, keys: ["app_enc_key", "appEncKey"])
        
        snap.appEncNonce =
        NuraMsg.stringValue(NuraMsg.value(typedActionDetail(body, "app_enc"), "nonce")) ??
        findStringInPayload(body, keys: ["app_enc_nonce", "appEncNonce"])
        
        return snap
    }
    
    /// Finds the detail map ("d") of a typed action { t:"t", c:<category> } inside body.d.a[].
    private static func typedActionDetail(_ body: [String: Any?], _ category: String) -> [String: Any?]? {
        guard let dataMap = NuraMsg.asMap(NuraMsg.value(body, "d")),
              let actions = NuraMsg.asArray(NuraMsg.value(dataMap, "a"))
                else { return nil }
        
        for action in actions {
            guard let actionMap = NuraMsg.asMap(action) else { continue }
            let type = NuraMsg.stringValue(NuraMsg.value(actionMap, "t"))
            let cat = NuraMsg.stringValue(NuraMsg.value(actionMap, "c"))
            if type?.caseInsensitiveCompare("t") == .orderedSame,
               cat?.caseInsensitiveCompare(category) == .orderedSame {
                return NuraMsg.asMap(NuraMsg.value(actionMap, "d"))
            }
        }
        return nil
    }
    
    private static func payloadMaps(_ body: [String: Any?]) -> [[String: Any?]] {
        var maps: [[String: Any?]] = [body]
        if let dataMap = NuraMsg.asMap(NuraMsg.value(body, "d")) {
            maps.append(dataMap)
        }
        return maps
    }
    
    private static func findIntInPayload(_ body: [String: Any?], keys: [String]) -> Int? {
        for map in payloadMaps(body) {
            for key in keys {
                if let v = NuraMsg.intValue(NuraMsg.value(map, key)) { return v }
            }
        }
        return nil
    }
    
    private static func findStringInPayload(_ body: [String: Any?], keys: [String]) -> String? {
        for map in payloadMaps(body) {
            for key in keys {
                if let v = NuraMsg.stringValue(NuraMsg.value(map, key)), !v.isEmpty { return v }
            }
        }
        return nil
    }
}

// MARK: - session/start continuation actions

struct NuraSessionStartPacket {
    let flagE: Bool
    let flagA: Bool
    let flagM: Bool
    let payloadBytes: [UInt8]?
}

struct NuraSessionStartDetails {
    var sessionId: Int?
    var finalEvent: String?
    var packets: [NuraSessionStartPacket] = []      // type "u"
    var runPackets: [NuraSessionStartPacket] = []   // type "r"
}

enum NuraSessionStartResponseParser {
    
    static func parse(_ body: [String: Any?]) -> NuraSessionStartDetails? {
        guard let dataMap = NuraMsg.asMap(NuraMsg.value(body, "d")) else { return nil }
        
        var details = NuraSessionStartDetails()
        details.sessionId = intFromTypedAction(dataMap, category: "session")
        details.finalEvent = finalEvent(dataMap)
        details.packets = packets(dataMap, actionType: "u")
        details.runPackets = packets(dataMap, actionType: "r")
        return details
    }
    
    private static func actionMaps(_ dataMap: [String: Any?]) -> [[String: Any?]] {
        guard let actions = NuraMsg.asArray(NuraMsg.value(dataMap, "a")) else { return [] }
        return actions.compactMap { NuraMsg.asMap($0) }
    }
    
    private static func intFromTypedAction(_ dataMap: [String: Any?], category: String) -> Int? {
        for action in actionMaps(dataMap) {
            let type = NuraMsg.stringValue(NuraMsg.value(action, "t"))
            let cat = NuraMsg.stringValue(NuraMsg.value(action, "c"))
            if type?.caseInsensitiveCompare("t") == .orderedSame,
               cat?.caseInsensitiveCompare(category) == .orderedSame {
                return NuraMsg.intValue(NuraMsg.value(action, "d"))
            }
        }
        return nil
    }
    
    private static func finalEvent(_ dataMap: [String: Any?]) -> String? {
        for action in actionMaps(dataMap) {
            let type = NuraMsg.stringValue(NuraMsg.value(action, "t"))
            if type?.caseInsensitiveCompare("f") == .orderedSame {
                if let value = NuraMsg.stringValue(NuraMsg.value(action, "e")), !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }
    
    private static func packets(_ dataMap: [String: Any?], actionType: String) -> [NuraSessionStartPacket] {
        var result: [NuraSessionStartPacket] = []
        for action in actionMaps(dataMap) {
            let type = NuraMsg.stringValue(NuraMsg.value(action, "t"))
            guard type?.caseInsensitiveCompare(actionType) == .orderedSame else { continue }
            guard let packetNodes = NuraMsg.asArray(NuraMsg.value(action, "p")) else { continue }
            for node in packetNodes {
                guard let packetMap = NuraMsg.asMap(node) else { continue }
                result.append(NuraSessionStartPacket(
                    flagE: NuraMsg.boolValue(NuraMsg.value(packetMap, "e")) ?? false,
                    flagA: NuraMsg.boolValue(NuraMsg.value(packetMap, "a")) ?? false,
                    flagM: NuraMsg.boolValue(NuraMsg.value(packetMap, "m")) ?? false,
                    payloadBytes: NuraMsg.bytesValue(NuraMsg.value(packetMap, "b"))
                ))
            }
        }
        return result
    }
}
