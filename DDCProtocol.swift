import Foundation

// DDC/CI framing follows the MCCS commands used by AppleSiliconDDC (MIT).
enum DDCProtocol {
    static func getPacket(_ code: UInt8) -> [UInt8] {
        var packet: [UInt8] = [0x82, 0x01, code, 0]
        packet[3] = packet[0] ^ packet[1] ^ packet[2] ^ 0x6e
        return packet
    }

    static func setPacket(_ code: UInt8, value: UInt16) -> [UInt8] {
        var packet: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xff), 0]
        packet[5] = packet.dropLast().reduce(UInt8(0x6e ^ 0x51), ^)
        return packet
    }

    static func parse(_ response: [UInt8], code: UInt8) -> (current: UInt16, maximum: UInt16)? {
        guard response.count == 11,
              response.dropLast().reduce(UInt8(0x50), ^) == response[10],
              response[0] == 0x6e, response[1] == 0x88,
              response[2] == 0x02, response[3] == 0,
              response[4] == code, response[5] == 0 else { return nil }
        let maximum = UInt16(response[6]) << 8 | UInt16(response[7])
        let current = UInt16(response[8]) << 8 | UInt16(response[9])
        guard maximum > 0, current <= maximum else { return nil }
        return (current, maximum)
    }
}
