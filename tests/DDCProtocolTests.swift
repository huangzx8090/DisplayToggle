import Foundation

@main
struct DDCProtocolTests {
    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fatalError("FAIL: \(name)") }
        print("PASS: \(name)")
    }
    static func main() {
        check(DDCProtocol.getPacket(0x10) == [0x82, 0x01, 0x10, 0xfd], "亮度读取报文")
        check(DDCProtocol.setPacket(0x10, value: 14) == [0x84, 0x03, 0x10, 0, 14, 0xa6], "亮度写入报文")
        let reply: [UInt8] = [0x6e, 0x88, 0x02, 0, 0x10, 0, 0, 100, 0, 13, 0xcd]
        let value = DDCProtocol.parse(reply, code: 0x10)
        check(value?.current == 13 && value?.maximum == 100, "解析真实设备回复")
        check(DDCProtocol.parse(reply, code: 0x12) == nil, "拒绝其他功能的旧回复")
        var bad = reply
        bad[10] ^= 1
        check(DDCProtocol.parse(bad, code: 0x10) == nil, "拒绝校验和错误")
        var momentary = reply
        momentary[5] = 1
        momentary[10] ^= 1
        check(DDCProtocol.parse(momentary, code: 0x10) == nil, "不将瞬时命令当作滑块")
        check(DDCProtocol.parse(Array(reply.dropLast()), code: 0x10) == nil, "拒绝不完整回复")
        print("DDC 报文测试全部通过")
    }
}
