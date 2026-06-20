import Foundation

enum MessagePackLite {

    static func serializeMap(_ map: [String: Any?]) -> Data {
        var buffer: [UInt8] = []
        writeMap(map, to: &buffer)
        return Data(buffer)
    }

    static func deserialize(_ data: Data) -> Any? {
        var offset = 0
        let bytes = [UInt8](data)
        return readValue(bytes, &offset)
    }

    // MARK: - Writer

    private static func writeMap(_ map: [String: Any?], to buffer: inout [UInt8]) {
        writeMapHeader(map.count, to: &buffer)
        for (key, value) in map {
            writeString(key, to: &buffer)
            writeValue(value, to: &buffer)
        }
    }

    private static func writeValue(_ value: Any?, to buffer: inout [UInt8]) {
        switch value {
        case nil:
            buffer.append(0xc0)
        case let text as String:
            writeString(text, to: &buffer)
        case let flag as Bool:
            buffer.append(flag ? 0xc3 : 0xc2)
        case let number as Int:
            writeSigned(Int64(number), to: &buffer)
        case let number as Int64:
            writeSigned(number, to: &buffer)
        case let number as UInt64:
            writeUnsigned(number, to: &buffer)
        case let nestedMap as [String: Any?]:
            writeMap(nestedMap, to: &buffer)
        case let array as [Any?]:
            writeArray(array, to: &buffer)
        case let bytes as [UInt8]:
            writeBinary(bytes, to: &buffer)
        case let data as Data:
            writeBinary([UInt8](data), to: &buffer)
        default:
            break
        }
    }

    private static func writeArray(_ values: [Any?], to buffer: inout [UInt8]) {
        if values.count <= 15 {
            buffer.append(UInt8(0x90 | values.count))
        } else if values.count <= 0xFFFF {
            buffer.append(0xdc)
            writeUInt16(UInt16(values.count), to: &buffer)
        } else {
            buffer.append(0xdd)
            writeUInt32(UInt32(values.count), to: &buffer)
        }
        for value in values { writeValue(value, to: &buffer) }
    }

    private static func writeMapHeader(_ count: Int, to buffer: inout [UInt8]) {
        if count <= 15 {
            buffer.append(UInt8(0x80 | count))
        } else if count <= 0xFFFF {
            buffer.append(0xde)
            writeUInt16(UInt16(count), to: &buffer)
        } else {
            buffer.append(0xdf)
            writeUInt32(UInt32(count), to: &buffer)
        }
    }

    private static func writeString(_ value: String, to buffer: inout [UInt8]) {
        let bytes = Array(value.utf8)
        if bytes.count <= 31 {
            buffer.append(UInt8(0xa0 | bytes.count))
        } else if bytes.count <= 0xFF {
            buffer.append(0xd9)
            buffer.append(UInt8(bytes.count))
        } else if bytes.count <= 0xFFFF {
            buffer.append(0xda)
            writeUInt16(UInt16(bytes.count), to: &buffer)
        } else {
            buffer.append(0xdb)
            writeUInt32(UInt32(bytes.count), to: &buffer)
        }
        buffer.append(contentsOf: bytes)
    }

    private static func writeBinary(_ bytes: [UInt8], to buffer: inout [UInt8]) {
        if bytes.count <= 0xFF {
            buffer.append(0xc4)
            buffer.append(UInt8(bytes.count))
        } else if bytes.count <= 0xFFFF {
            buffer.append(0xc5)
            writeUInt16(UInt16(bytes.count), to: &buffer)
        } else {
            buffer.append(0xc6)
            writeUInt32(UInt32(bytes.count), to: &buffer)
        }
        buffer.append(contentsOf: bytes)
    }

    private static func writeUnsigned(_ value: UInt64, to buffer: inout [UInt8]) {
        if value <= 0x7f {
            buffer.append(UInt8(value))
        } else if value <= 0xFF {
            buffer.append(0xcc)
            buffer.append(UInt8(value))
        } else if value <= 0xFFFF {
            buffer.append(0xcd)
            writeUInt16(UInt16(value), to: &buffer)
        } else if value <= 0xFFFF_FFFF {
            buffer.append(0xce)
            writeUInt32(UInt32(value), to: &buffer)
        } else {
            buffer.append(0xcf)
            writeUInt64(value, to: &buffer)
        }
    }

    private static func writeSigned(_ value: Int64, to buffer: inout [UInt8]) {
        if value >= 0 {
            writeUnsigned(UInt64(value), to: &buffer)
            return
        }
        if value >= -32 {
            buffer.append(UInt8(bitPattern: Int8(value)))
        } else if value >= Int64(Int8.min) {
            buffer.append(0xd0)
            buffer.append(UInt8(bitPattern: Int8(value)))
        } else if value >= Int64(Int16.min) {
            buffer.append(0xd1)
            writeUInt16(UInt16(bitPattern: Int16(value)), to: &buffer)
        } else if value >= Int64(Int32.min) {
            buffer.append(0xd2)
            writeUInt32(UInt32(bitPattern: Int32(value)), to: &buffer)
        } else {
            buffer.append(0xd3)
            writeUInt64(UInt64(bitPattern: value), to: &buffer)
        }
    }

    private static func writeUInt16(_ value: UInt16, to buffer: inout [UInt8]) {
        buffer.append(UInt8((value >> 8) & 0xFF))
        buffer.append(UInt8(value & 0xFF))
    }

    private static func writeUInt32(_ value: UInt32, to buffer: inout [UInt8]) {
        buffer.append(UInt8((value >> 24) & 0xFF))
        buffer.append(UInt8((value >> 16) & 0xFF))
        buffer.append(UInt8((value >> 8) & 0xFF))
        buffer.append(UInt8(value & 0xFF))
    }

    private static func writeUInt64(_ value: UInt64, to buffer: inout [UInt8]) {
        for i in stride(from: 56, through: 0, by: -8) {
            buffer.append(UInt8((value >> i) & 0xFF))
        }
    }

    // MARK: - Reader

    private static func readValue(_ data: [UInt8], _ offset: inout Int) -> Any? {
        guard offset < data.count else { return nil }
        let prefix = data[offset]
        offset += 1

        if prefix <= 0x7f { return Int(prefix) }
        if (prefix & 0xe0) == 0xa0 { return readString(data, &offset, length: Int(prefix & 0x1f)) }
        if (prefix & 0xf0) == 0x80 { return readMap(data, &offset, count: Int(prefix & 0x0f)) }
        if (prefix & 0xf0) == 0x90 { return readArray(data, &offset, count: Int(prefix & 0x0f)) }
        if prefix >= 0xe0 { return Int(Int8(bitPattern: prefix)) }

        switch prefix {
        case 0xc0: return nil
        case 0xc2: return false
        case 0xc3: return true
        case 0xc4: return readBinary(data, &offset, length: Int(readByte(data, &offset)))
        case 0xc5: return readBinary(data, &offset, length: Int(readUInt16(data, &offset)))
        case 0xc6: return readBinary(data, &offset, length: Int(readUInt32(data, &offset)))
        case 0xca: return readFloat32(data, &offset)
        case 0xcb: return readFloat64(data, &offset)
        case 0xcc: return Int(readByte(data, &offset))
        case 0xcd: return Int(readUInt16(data, &offset))
        case 0xce: return Int(readUInt32(data, &offset))
        case 0xcf: return Int(readUInt64(data, &offset))
        case 0xd0: return Int(Int8(bitPattern: readByte(data, &offset)))
        case 0xd1: return Int(Int16(bitPattern: readUInt16(data, &offset)))
        case 0xd2: return Int(Int32(bitPattern: readUInt32(data, &offset)))
        case 0xd3: return Int(Int64(bitPattern: readUInt64(data, &offset)))
        case 0xd9: return readString(data, &offset, length: Int(readByte(data, &offset)))
        case 0xda: return readString(data, &offset, length: Int(readUInt16(data, &offset)))
        case 0xdb: return readString(data, &offset, length: Int(readUInt32(data, &offset)))
        case 0xdc: return readArray(data, &offset, count: Int(readUInt16(data, &offset)))
        case 0xdd: return readArray(data, &offset, count: Int(readUInt32(data, &offset)))
        case 0xde: return readMap(data, &offset, count: Int(readUInt16(data, &offset)))
        case 0xdf: return readMap(data, &offset, count: Int(readUInt32(data, &offset)))
        default: return nil
        }
    }

    private static func readMap(_ data: [UInt8], _ offset: inout Int, count: Int) -> [String: Any?] {
        var map: [String: Any?] = [:]
        for _ in 0..<count {
            guard let key = readValue(data, &offset) as? String else { continue }
            map[key] = readValue(data, &offset)
        }
        return map
    }

    private static func readArray(_ data: [UInt8], _ offset: inout Int, count: Int) -> [Any?] {
        var list: [Any?] = []
        for _ in 0..<count {
            list.append(readValue(data, &offset))
        }
        return list
    }

    private static func readString(_ data: [UInt8], _ offset: inout Int, length: Int) -> String {
        guard offset + length <= data.count else { return "" }
        let str = String(bytes: data[offset..<offset + length], encoding: .utf8) ?? ""
        offset += length
        return str
    }

    private static func readBinary(_ data: [UInt8], _ offset: inout Int, length: Int) -> [UInt8] {
        guard offset + length <= data.count else { return [] }
        let bytes = Array(data[offset..<offset + length])
        offset += length
        return bytes
    }

    private static func readFloat32(_ data: [UInt8], _ offset: inout Int) -> Float {
        let bytes = readBinary(data, &offset, length: 4)
        var value: UInt32 = 0
        for b in bytes { value = (value << 8) | UInt32(b) }
        return Float(bitPattern: value)
    }

    private static func readFloat64(_ data: [UInt8], _ offset: inout Int) -> Double {
        let bytes = readBinary(data, &offset, length: 8)
        var value: UInt64 = 0
        for b in bytes { value = (value << 8) | UInt64(b) }
        return Double(bitPattern: value)
    }

    private static func readByte(_ data: [UInt8], _ offset: inout Int) -> UInt8 {
        guard offset < data.count else { return 0 }
        let b = data[offset]
        offset += 1
        return b
    }

    private static func readUInt16(_ data: [UInt8], _ offset: inout Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        let value = (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
        offset += 2
        return value
    }

    private static func readUInt32(_ data: [UInt8], _ offset: inout Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        var value: UInt32 = 0
        for i in 0..<4 { value = (value << 8) | UInt32(data[offset + i]) }
        offset += 4
        return value
    }

    private static func readUInt64(_ data: [UInt8], _ offset: inout Int) -> UInt64 {
        guard offset + 8 <= data.count else { return 0 }
        var value: UInt64 = 0
        for i in 0..<8 { value = (value << 8) | UInt64(data[offset + i]) }
        offset += 8
        return value
    }
}
