import Foundation

enum HeadsetIndicationParser {

    static func parse(_ response: GaiaResponse) -> HeadsetIndication? {
        let payload = response.payloadExcludingStatus
        guard payload.count == 2,
              let id = HeadsetIndicationId(rawValue: payload[0])
        else { return nil }
        return HeadsetIndication(identifier: id, value: payload[1])
    }

    static func decodeNuraphoneAncState(_ value: UInt8) -> NuraAncState {
        NuraAncState(
            ancEnabled: (value & 1) != 0,
            passthroughEnabled: (value & 2) != 0
        )
    }
}
