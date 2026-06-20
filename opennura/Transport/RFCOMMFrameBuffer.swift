#if os(macOS)
import Foundation

final class RFCOMMFrameBuffer {
    private var buffer: [UInt8] = []

    func append(_ data: Data) {
        buffer.append(contentsOf: data)
    }

    func tryReadFrame() -> [UInt8]? {
        guard let sofIndex = buffer.firstIndex(of: 0xFF) else {
            buffer.removeAll()
            return nil
        }

        if sofIndex > 0 {
            buffer.removeFirst(sofIndex)
        }

        guard buffer.count >= 4 else { return nil }

        let usesLengthExtension = (buffer[2] & 0x02) != 0
        let headerLength = usesLengthExtension ? 9 : 8

        guard buffer.count >= headerLength else { return nil }

        let payloadLength: Int
        if usesLengthExtension {
            payloadLength = (Int(buffer[3]) << 8) | Int(buffer[4])
        } else {
            payloadLength = Int(buffer[3])
        }

        let totalLength = headerLength + payloadLength
        guard buffer.count >= totalLength else { return nil }

        let frame = Array(buffer[0..<totalLength])
        buffer.removeFirst(totalLength)
        return frame
    }

    func reset() {
        buffer.removeAll()
    }
}
#endif
